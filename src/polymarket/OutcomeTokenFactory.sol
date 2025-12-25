// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import {OutcomeTokenWrapper} from "./OutcomeTokenWrapper.sol";

/// @title OutcomeTokenFactory
/// @notice Deploys ERC20 wrappers for Polymarket outcome ERC1155 tokens
contract OutcomeTokenFactory {
    /// @notice Conditional Tokens contract that minted the ERC1155 outcomes
    IERC1155 public immutable conditionalTokens;

    event OutcomeTokenCreated(uint256 indexed tokenId, address wrapper);

    constructor(IERC1155 conditionalTokens_) {
        conditionalTokens = conditionalTokens_;
    }

    /// @notice Deploy a wrapper for the given outcome token id
    /// @param tokenId ERC1155 id for the outcome token
    /// @param name ERC20 name for the wrapper
    /// @param symbol ERC20 symbol for the wrapper
    /// @return wrapper Address of the deployed wrapper
    function createOutcomeToken(uint256 tokenId, string memory name, string memory symbol)
        external
        returns (OutcomeTokenWrapper wrapper)
    {
        wrapper = new OutcomeTokenWrapper(conditionalTokens, tokenId, name, symbol);
        emit OutcomeTokenCreated(tokenId, address(wrapper));
    }
}
