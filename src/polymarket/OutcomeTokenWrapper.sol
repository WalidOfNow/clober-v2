// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";

/// @title OutcomeTokenWrapper
/// @notice Wraps a Polymarket conditional token (ERC1155) into an ERC20 that can be used by the CLOB
contract OutcomeTokenWrapper is ERC20, ERC1155Holder {
    /// @notice Conditional Tokens contract backing the wrapped outcome token
    IConditionalTokens public immutable conditionalTokens;

    /// @notice The ERC1155 id representing the outcome
    uint256 public immutable tokenId;

    constructor(IConditionalTokens conditionalTokens_, uint256 tokenId_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {
        conditionalTokens = conditionalTokens_;
        tokenId = tokenId_;
    }

    /// @notice Wraps ERC1155 outcome tokens into ERC20 shares
    /// @param to Recipient of the wrapped ERC20
    /// @param amount Amount of ERC1155 tokens to wrap
    /// @return minted Amount of ERC20 tokens minted
    function depositFor(address to, uint256 amount) external returns (uint256 minted) {
        minted = amount;
        conditionalTokens.safeTransferFrom(msg.sender, address(this), tokenId, amount, "");
        _mint(to, minted);
    }

    /// @notice Burns wrapped ERC20 shares and returns the underlying ERC1155 outcome tokens
    /// @param to Recipient of the ERC1155 tokens
    /// @param amount Amount of ERC20 to unwrap
    /// @return withdrawn Amount of ERC1155 tokens returned
    function withdrawTo(address to, uint256 amount) external returns (uint256 withdrawn) {
        withdrawn = amount;
        _burn(msg.sender, withdrawn);
        conditionalTokens.safeTransferFrom(address(this), to, tokenId, withdrawn, "");
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
