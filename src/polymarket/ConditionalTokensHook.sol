// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import {IBookManager} from "../interfaces/IBookManager.sol";
import {IHooks} from "../interfaces/IHooks.sol";
import {BookId, BookIdLibrary} from "../libraries/BookId.sol";
import {Currency, CurrencyLibrary} from "../libraries/Currency.sol";
import {Hooks} from "../libraries/Hooks.sol";
import {OrderId, OrderIdLibrary} from "../libraries/OrderId.sol";

import {OutcomeTokenFactory} from "./OutcomeTokenFactory.sol";
import {OutcomeTokenWrapper} from "./OutcomeTokenWrapper.sol";

/// @title ConditionalTokensHook
/// @notice Hook that maps Polymarket conditional outcome tokens to Clober books and enforces market lifecycle
contract ConditionalTokensHook is IHooks, Ownable {
    using BookIdLibrary for IBookManager.BookKey;
    using CurrencyLibrary for Currency;

    /// @notice Config used when opening a market-backed book
    struct MarketCreationParams {
        bytes32 conditionId;
        uint256 yesTokenId;
        uint256 noTokenId;
        uint64 cutoffTime;
        string yesName;
        string yesSymbol;
        string noName;
        string noSymbol;
        address yesWrapper;
        address noWrapper;
    }

    struct MarketState {
        bytes32 conditionId;
        uint256 yesTokenId;
        uint256 noTokenId;
        uint64 cutoffTime;
        bool resolved;
        uint256 winningTokenId;
        OutcomeTokenWrapper yesWrapper;
        OutcomeTokenWrapper noWrapper;
    }

    IERC1155 public immutable conditionalTokens;
    OutcomeTokenFactory public immutable outcomeFactory;

    mapping(BookId id => MarketState) public markets;

    error MarketExists(BookId id);
    error MarketNotFound(BookId id);
    error MarketClosed(BookId id);
    error MarketResolved(BookId id, uint256 winningTokenId);
    error CurrencyMismatch(BookId id, Currency expected, Currency provided);
    error InvalidResolution(BookId id, uint256 winningTokenId);
    error UnsupportedWrapper(BookId id, address wrapper);

    constructor(IERC1155 conditionalTokens_, OutcomeTokenFactory outcomeFactory_) Ownable() {
        conditionalTokens = conditionalTokens_;
        outcomeFactory = outcomeFactory_;

        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeOpen: true,
                afterOpen: false,
                beforeMake: true,
                afterMake: false,
                beforeTake: true,
                afterTake: false,
                beforeCancel: true,
                afterCancel: false,
                beforeClaim: true,
                afterClaim: false
            })
        );
    }

    /// @notice Resolve a market by selecting the winning token id (must be yesTokenId or noTokenId)
    function resolveMarket(BookId id, uint256 winningTokenId) external onlyOwner {
        MarketState storage market = markets[id];
        if (market.conditionId == bytes32(0)) revert MarketNotFound(id);
        if (market.resolved) revert MarketResolved(id, market.winningTokenId);
        if (winningTokenId != market.yesTokenId && winningTokenId != market.noTokenId) {
            revert InvalidResolution(id, winningTokenId);
        }

        market.resolved = true;
        market.winningTokenId = winningTokenId;
    }

    /// @inheritdoc IHooks
    function beforeOpen(address, IBookManager.BookKey calldata key, bytes calldata hookData)
        external
        returns (bytes4)
    {
        BookId bookId = key.toId();
        if (markets[bookId].conditionId != bytes32(0)) revert MarketExists(bookId);

        MarketCreationParams memory params = abi.decode(hookData, (MarketCreationParams));

        OutcomeTokenWrapper yesWrapper = _wrapperOrCreate(
            params.yesWrapper, params.yesTokenId, params.yesName, params.yesSymbol
        );
        OutcomeTokenWrapper noWrapper = _wrapperOrCreate(
            params.noWrapper, params.noTokenId, params.noName, params.noSymbol
        );

        if (address(yesWrapper.conditionalTokens()) != address(conditionalTokens)) {
            revert UnsupportedWrapper(bookId, address(yesWrapper));
        }
        if (address(noWrapper.conditionalTokens()) != address(conditionalTokens)) {
            revert UnsupportedWrapper(bookId, address(noWrapper));
        }

        if (!key.base.equals(Currency.wrap(address(yesWrapper)))) {
            revert CurrencyMismatch(bookId, Currency.wrap(address(yesWrapper)), key.base);
        }
        if (!key.quote.equals(Currency.wrap(address(noWrapper)))) {
            revert CurrencyMismatch(bookId, Currency.wrap(address(noWrapper)), key.quote);
        }

        markets[bookId] = MarketState({
            conditionId: params.conditionId,
            yesTokenId: params.yesTokenId,
            noTokenId: params.noTokenId,
            cutoffTime: params.cutoffTime,
            resolved: false,
            winningTokenId: 0,
            yesWrapper: yesWrapper,
            noWrapper: noWrapper
        });

        return IHooks.beforeOpen.selector;
    }

    /// @inheritdoc IHooks
    function beforeMake(address, IBookManager.MakeParams calldata params, bytes calldata)
        external
        returns (bytes4)
    {
        _verifyOpen(params.key.toId());
        return IHooks.beforeMake.selector;
    }

    /// @inheritdoc IHooks
    function beforeTake(address, IBookManager.TakeParams calldata params, bytes calldata)
        external
        returns (bytes4)
    {
        _verifyOpen(params.key.toId());
        return IHooks.beforeTake.selector;
    }

    /// @inheritdoc IHooks
    function beforeCancel(address, IBookManager.CancelParams calldata params, bytes calldata)
        external
        returns (bytes4)
    {
        BookId bookId = params.id.getBookId();
        if (markets[bookId].conditionId == bytes32(0)) revert MarketNotFound(bookId);
        return IHooks.beforeCancel.selector;
    }

    /// @inheritdoc IHooks
    function beforeClaim(address, OrderId orderId, bytes calldata) external returns (bytes4) {
        BookId bookId = orderId.getBookId();
        if (markets[bookId].conditionId == bytes32(0)) revert MarketNotFound(bookId);
        return IHooks.beforeClaim.selector;
    }

    function _verifyOpen(BookId id) internal view {
        MarketState storage market = markets[id];
        if (market.conditionId == bytes32(0)) revert MarketNotFound(id);
        if (market.resolved) revert MarketResolved(id, market.winningTokenId);
        if (block.timestamp > market.cutoffTime) revert MarketClosed(id);
    }

    function _wrapperOrCreate(address wrapper, uint256 tokenId, string memory name, string memory symbol)
        internal
        returns (OutcomeTokenWrapper)
    {
        if (wrapper != address(0)) return OutcomeTokenWrapper(wrapper);
        return outcomeFactory.createOutcomeToken(tokenId, name, symbol);
    }
}
