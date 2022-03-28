// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Apollo.sol";

contract ApolloFactory {
    // Returns the address of the newly deployed contract
    Apollo public  apollo;
    function deploy(
        IERC20 usdc,
        IUniswapV2Router02 _router,
        address presaleAddress,
        bytes32 _salt
    ) public payable returns (address) {
        // This syntax is a newer way to invoke create2 without assembly, you just need to pass salt
        // https://docs.soliditylang.org/en/latest/control-structures.html#salted-contract-creations-create2
        apollo = new Apollo{salt: _salt}(usdc, _router, presaleAddress);
        return address(apollo);
    }
}
