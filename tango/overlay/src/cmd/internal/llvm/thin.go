// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
// Copyright (c) 2026 ByteDance Ltd. and/or its affiliates.

//go:build goexperiment.tangollvm && linux && amd64 && cgo && !compiler_bootstrap

package llvm

import (
	"cmd/internal/archive"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"internal/buildcfg"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sync"
)

type thinModule struct {
	Module    string
	Index     string
	Sources   []string
	Functions int
}

func thinSummary(path, work string, occurrences map[string]int) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	a, err := archive.Parse(f, false)
	if err != nil {
		return "", err
	}
	for _, entry := range a.Entries {
		if entry.Name != archive.ThinLTOEntry {
			continue
		}
		tmp, err := os.CreateTemp(work, ".summary-")
		if err != nil {
			return "", err
		}
		defer os.Remove(tmp.Name())
		h := sha256.New()
		size, err := io.Copy(io.MultiWriter(tmp, h), io.NewSectionReader(f, entry.Offset, entry.Size))
		if err := errors.Join(err, tmp.Close()); err != nil {
			return "", err
		}
		if size != entry.Size {
			return "", io.ErrUnexpectedEOF
		}
		digest := fmt.Sprintf("%x", h.Sum(nil))
		name := fmt.Sprintf("%s-%d.bc", digest, occurrences[digest])
		occurrences[digest]++
		return name, os.Rename(tmp.Name(), filepath.Join(work, name))
	}
	return "", nil
}

func thinFileHash(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", h.Sum(nil)), nil
}

// Copy through a temporary file on the destination filesystem so concurrent
// links cannot observe a partially published cached object.
func copyThinObject(src, dst string) error {
	f, err := os.Open(src)
	if err != nil {
		return err
	}
	defer f.Close()
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".thin-object-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_, err = io.Copy(tmp, f)
	if err := errors.Join(err, tmp.Close()); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), dst)
}

func thinCacheDir() string {
	root := os.Getenv("GOCACHE")
	if root == "off" {
		return ""
	}
	if root == "" {
		user, err := os.UserCacheDir()
		if err != nil {
			return ""
		}
		root = filepath.Join(user, "go-build")
	}
	return filepath.Join(root, "tangollvm-thin")
}

func (t *Tools) RunThinLTO(archives []string, workers, memory int, budget uint) ([]string, error) {
	if workers < 1 || memory < 1 {
		return nil, fmt.Errorf("ThinLTO backend limits must be positive")
	}
	work, err := os.MkdirTemp(t.dir, "tangollvm-thin-")
	if err != nil {
		return nil, err
	}
	work, err = filepath.Abs(work)
	if err != nil {
		return nil, err
	}
	local := *t
	local.dir = work

	var inputs []string
	seen := make(map[string]bool)
	occurrences := make(map[string]int)
	for _, path := range archives {
		if seen[path] {
			continue
		}
		seen[path] = true
		module, err := thinSummary(path, work, occurrences)
		if err != nil {
			return nil, fmt.Errorf("extract ThinLTO summary from %q: %w", path, err)
		}
		if module != "" {
			inputs = append(inputs, module)
		}
	}
	if len(inputs) == 0 {
		return nil, fmt.Errorf("no ThinLTO summaries; compile packages with -beast=llvm=3,thin-lto=1")
	}
	slices.Sort(inputs)
	if err := local.RunShell("llvm-lto", append([]string{"-thinlto-action=thinlink", "-o", "combined.bc"}, inputs...)...); err != nil {
		return nil, fmt.Errorf("thinlink: %w", err)
	}
	planner := exec.Command(t.GetToolPath("tango-thinlto-plan"), "combined.bc", "-output=.", fmt.Sprintf("-budget=%d", budget))
	planner.Dir = work
	planner.Stderr = os.Stderr
	plan, err := planner.Output()
	if err != nil {
		return nil, fmt.Errorf("ThinLTO planner: %w", err)
	}
	var modules []thinModule
	if err := json.Unmarshal(plan, &modules); err != nil {
		return nil, err
	}
	if len(modules) != len(inputs) {
		return nil, fmt.Errorf("ThinLTO planner returned %d backends for %d inputs", len(modules), len(inputs))
	}

	triple, err := GetLLVMTriple()
	if err != nil {
		return nil, err
	}
	target := []string{"-mtriple=" + triple, "-mattr=" + GetLLVMFeatures(buildcfg.GOAMD64)}
	optArgs := append(slices.Clone(target), "-passes=function-import,gorodata,thinlto<O3>,gorodata",
		"-import-all-index", "-go-specialization=false")
	llcArgs := append(slices.Clone(target), "-filetype=obj", "-relocation-model=static",
		"-O3", "-cost-kind=latency", "-tangollvm-lto=true")
	cache := thinCacheDir()
	var toolHashes []string
	if cache != "" {
		if err := os.MkdirAll(cache, 0755); err != nil {
			return nil, err
		}
		for _, path := range []string{t.GetToolPath("opt"), t.GetToolPath("llc"),
			t.GetToolPath("llvm-lto"), planner.Path, filepath.Join(DefaultLibraryPath(), "libLLVM.so")} {
			hash, err := thinFileHash(path)
			if err != nil {
				return nil, err
			}
			toolHashes = append(toolHashes, hash)
		}
	}

	// Reserve an estimated 512 MiB per worker. Individual backends may exceed
	// that estimate. The budget controls admission.
	workers = min(workers, len(modules), max(1, memory/512))
	outputs := make([]string, len(modules))
	hits := make([]bool, len(modules))
	errs := make([]error, len(modules))
	jobs := make(chan int)
	var wg sync.WaitGroup
	for range workers {
		wg.Go(func() {
			for i := range jobs {
				outputs[i] = filepath.Join(work, fmt.Sprintf("%d.o", i))
				hits[i], errs[i] = local.compileThin(modules[i], optArgs, llcArgs, toolHashes, cache, outputs[i])
			}
		})
	}
	for i := range modules {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
	hitCount, imports := 0, 0
	for i, m := range modules {
		if errs[i] != nil {
			return nil, fmt.Errorf("ThinLTO backend %s: %w", m.Module, errs[i])
		}
		if hits[i] {
			hitCount++
		}
		imports += m.Functions
	}
	fmt.Fprintf(os.Stderr, "ThinLTO: %d modules, %d imported bodies, %d workers; cache %d hits, %d misses\n",
		len(modules), imports, workers, hitCount, len(modules)-hitCount)
	return outputs, nil
}

func (t *Tools) compileThin(m thinModule, optArgs, llcArgs, toolHashes []string, cache, output string) (bool, error) {
	var cached string
	if cache != "" {
		index, err := thinFileHash(filepath.Join(t.dir, m.Index))
		if err != nil {
			return false, err
		}
		// Module and source names incorporate the hashes of their contents.
		key, err := json.Marshal([]any{"tango-thin-v1", m.Module, m.Sources, index, optArgs, llcArgs, toolHashes})
		if err != nil {
			return false, err
		}
		cached = filepath.Join(cache, fmt.Sprintf("%x.o", sha256.Sum256(key)))
		if err := copyThinObject(cached, output); err == nil {
			return true, nil
		} else if !os.IsNotExist(err) {
			return false, err
		}
	}
	bc := output + ".bc"
	if err := t.RunShell("opt", append(slices.Clone(optArgs), "-summary-file="+m.Index, "-o", bc, m.Module)...); err != nil {
		return false, fmt.Errorf("opt: %w", err)
	}
	if err := t.RunShell("llc", append(slices.Clone(llcArgs), "-o", output, bc)...); err != nil {
		return false, fmt.Errorf("llc: %w", err)
	}
	if cached != "" {
		return false, copyThinObject(output, cached)
	}
	return false, nil
}
