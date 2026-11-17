// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Create2Factory — minimal deterministic deployment factory.
/// @notice Used to mine the RebateHook address so that its permission bits
///         (address & 0x3FFF == 0x1040) are exact.
contract Create2Factory {
    event Deployed(address indexed addr, bytes32 indexed salt);

    error DeployFailed();

    /// @notice Deploy `code` with `salt` via CREATE2.
    /// @return addr the deployed contract address (0-checked)
    function deploy(bytes memory code, bytes32 salt) external returns (address addr) {
        assembly {
            addr := create2(0, add(code, 0x20), mload(code), salt)
        }
        if (addr == address(0)) revert DeployFailed();
        emit Deployed(addr, salt);
    }

    /// @notice Predict the CREATE2 address for `salt` and init-code hash.
    function predictAddress(bytes32 salt, bytes32 codeHash) external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, codeHash)))));
    }
}
