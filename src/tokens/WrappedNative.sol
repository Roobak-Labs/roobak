// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title WrappedNative — WETH9-style wrapper for the chain's native gas asset.
/// @notice Standard deposit/withdraw wrapper so pools can treat the native asset
///         as an ERC-20 quote/base currency. Testnet fixture; not branded.
contract WrappedNative {
    string public constant name = "Wrapped Native Token";
    string public constant symbol = "WNT";
    uint8 public constant decimals = 18;

    event Approval(address indexed src, address indexed dst, uint256 amount);
    event Transfer(address indexed src, address indexed dst, uint256 amount);
    event Deposit(address indexed dst, uint256 amount);
    event Withdrawal(address indexed src, uint256 amount);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) public {
        uint256 balance = balanceOf[msg.sender];
        require(balance >= amount, "WNT: insufficient balance");
        unchecked {
            balanceOf[msg.sender] = balance - amount;
        }
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "WNT: transfer failed");
        emit Withdrawal(msg.sender, amount);
    }

    function totalSupply() external view returns (uint256) {
        return address(this).balance;
    }

    function approve(address dst, uint256 amount) external returns (bool) {
        allowance[msg.sender][dst] = amount;
        emit Approval(msg.sender, dst, amount);
        return true;
    }

    function transfer(address dst, uint256 amount) external returns (bool) {
        _transfer(msg.sender, dst, amount);
        return true;
    }

    function transferFrom(address src, address dst, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[src][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "WNT: insufficient allowance");
            allowance[src][msg.sender] = allowed - amount;
        }
        _transfer(src, dst, amount);
        return true;
    }

    function _transfer(address src, address dst, uint256 amount) internal {
        uint256 balance = balanceOf[src];
        require(balance >= amount, "WNT: insufficient balance");
        unchecked {
            balanceOf[src] = balance - amount;
            balanceOf[dst] += amount;
        }
        emit Transfer(src, dst, amount);
    }
}
