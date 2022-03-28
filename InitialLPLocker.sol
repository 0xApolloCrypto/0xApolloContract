// SPDX-License-Identifier: Unlicensed

// Apollo PROTOCOL COPYRIGHT (C) 2022

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract InitialLPLocker {
    using SafeERC20 for IERC20;
    uint256 public unlockAt;
    address public owner;

    constructor() {
        // lock any erc20 token  1 year
        unlockAt = block.timestamp + 365 days;
        owner = tx.origin;
    }

    function changeOwner(address newOwner) public {
        require(msg.sender == owner, "Only owner can change owner");
        owner = newOwner;
    }

    function recover(
        IERC20 token,
        address receiver,
        uint256 amount
    ) public {
        require(msg.sender == owner, "Only owner");
        require(block.timestamp > unlockAt, "Locker is not unlocked yet");
        token.safeTransfer(receiver, amount);
    }
}
