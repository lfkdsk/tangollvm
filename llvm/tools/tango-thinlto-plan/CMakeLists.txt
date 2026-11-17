set(LLVM_LINK_COMPONENTS BitReader BitWriter Core IPO Support)
add_llvm_tool(tango-thinlto-plan tango-thinlto-plan.cpp)
