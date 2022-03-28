
// Apollo PROTOCOL COPYRIGHT (C) 2022

pragma solidity ^0.8.0;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IApollo is IERC20, IERC20Metadata {
    function getCirculatingSupply() external view returns (uint256);
}
