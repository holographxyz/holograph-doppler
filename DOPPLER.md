1. Identified the root cause: The issue was with OpenZeppelin contract import remappings in a complex nested Foundry project structure.

2. Created a symlink solution: Since the remapping precedence conflicts between multiple nested foundry projects were complex to resolve, I created a symlink directly in the doppler subproject:

cd lib/doppler && ln -sf lib/v4-core/lib/openzeppelin-contracts/contracts @openzeppelin
