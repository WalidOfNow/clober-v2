// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBookManager} from "../interfaces/IBookManager.sol";
import {IHooks} from "../interfaces/IHooks.sol";
import {BookId, BookIdLibrary} from "../libraries/BookId.sol";
import {Currency, CurrencyLibrary} from "../libraries/Currency.sol";
import {Hooks} from "../libraries/Hooks.sol";
import {OrderId, OrderIdLibrary} from "../libraries/OrderId.sol";

import {OutcomeTokenFactory} from "./OutcomeTokenFactory.sol";
import {OutcomeTokenWrapper} from "./OutcomeTokenWrapper.sol";
import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";

/// @title ConditionalTokensHook
/// @notice Hook that maps Polymarket conditional outcome tokens to Clober books and enforces market lifecycle
contract ConditionalTokensHook is IHooks, Ownable {
    using SafeERC20 for IERC20;
    using BookIdLibrary for IBookManager.BookKey;
    using CurrencyLibrary for Currency;

    enum MatchType {
        Complementary,
        Mint,
        Merge
    }

    struct TakeHookData {
        MatchType matchType;
        address baseRecipient;
        address quoteRecipient;
        address collateralSource;
        address collateralRecipient;
        address baseProvider;
        address quoteProvider;
    }

    /// @notice Config used when opening a market-backed book
    struct MarketCreationParams {
        bytes32 conditionId;
        uint256 yesTokenId;
        uint256 noTokenId;
        Currency collateral;
        bytes32 parentCollectionId;
        uint256[2] partition;
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
        Currency collateral;
        bytes32 parentCollectionId;
        uint256[2] partition;
        uint64 cutoffTime;
        bool resolved;
        uint256 winningTokenId;
        OutcomeTokenWrapper yesWrapper;
        OutcomeTokenWrapper noWrapper;
    }

    IConditionalTokens public immutable conditionalTokens;
    OutcomeTokenFactory public immutable outcomeFactory;

    mapping(BookId id => MarketState) public markets;

    error InvalidCollateral(BookId id);
    error MarketExists(BookId id);
    error MarketNotFound(BookId id);
    error MarketClosed(BookId id);
    error MarketResolved(BookId id, uint256 winningTokenId);
    error CurrencyMismatch(BookId id, Currency expected, Currency provided);
    error InvalidResolution(BookId id, uint256 winningTokenId);
    error UnsupportedWrapper(BookId id, address wrapper);
    error InvalidPartition(BookId id, uint256[2] partition);

    constructor(IConditionalTokens conditionalTokens_, OutcomeTokenFactory outcomeFactory_) Ownable() {
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
                afterTake: true,
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

        _validatePartition(bookId, params.partition);

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
            collateral: params.collateral,
            parentCollectionId: params.parentCollectionId,
            partition: params.partition,
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
    function afterTake(address sender, IBookManager.TakeParams calldata params, uint64 takenUnit, bytes calldata hookData)
        external
        returns (bytes4)
    {
        BookId bookId = params.key.toId();
        MarketState storage market = _verifyOpen(bookId);
        if (takenUnit == 0) return IHooks.afterTake.selector;

        TakeHookData memory data = _decodeTakeHookData(sender, hookData);
        if (data.matchType == MatchType.Complementary) return IHooks.afterTake.selector;

        uint256 amount = uint256(takenUnit) * params.key.unitSize;
        if (data.matchType == MatchType.Mint) {
            _mintOutcomes(bookId, market, amount, data);
        } else if (data.matchType == MatchType.Merge) {
            _mergeOutcomes(bookId, market, amount, data);
        }

        return IHooks.afterTake.selector;
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

    function _mintOutcomes(BookId id, MarketState storage market, uint256 amount, TakeHookData memory data) internal {
        if (market.collateral.isNative()) revert InvalidCollateral(id);

        IERC20 collateralToken = IERC20(Currency.unwrap(market.collateral));
        collateralToken.safeTransferFrom(data.collateralSource, address(this), amount);

        uint256[] memory partition = _toPartition(market.partition);
        conditionalTokens.splitPosition(
            Currency.unwrap(market.collateral), market.parentCollectionId, market.conditionId, partition, amount
        );

        market.yesWrapper.depositFor(data.baseRecipient, amount);
        market.noWrapper.depositFor(data.quoteRecipient, amount);
    }

    function _mergeOutcomes(BookId id, MarketState storage market, uint256 amount, TakeHookData memory data) internal {
        if (market.collateral.isNative()) revert InvalidCollateral(id);

        market.yesWrapper.transferFrom(data.baseProvider, address(this), amount);
        market.noWrapper.transferFrom(data.quoteProvider, address(this), amount);

        market.yesWrapper.withdrawTo(address(this), amount);
        market.noWrapper.withdrawTo(address(this), amount);

        uint256[] memory partition = _toPartition(market.partition);
        conditionalTokens.mergePositions(
            Currency.unwrap(market.collateral), market.parentCollectionId, market.conditionId, partition, amount
        );

        Currency collateral = market.collateral;
        collateral.transfer(data.collateralRecipient, amount);
    }

    function _validatePartition(BookId id, uint256[2] memory partition) internal pure {
        if (partition[0] == 0 || partition[1] == 0) revert InvalidPartition(id, partition);
    }

    function _toPartition(uint256[2] memory partition) internal pure returns (uint256[] memory parts) {
        parts = new uint256[](2);
        parts[0] = partition[0];
        parts[1] = partition[1];
    }

    function _decodeTakeHookData(address sender, bytes calldata hookData)
        internal
        pure
        returns (TakeHookData memory data)
    {
        if (hookData.length > 0) {
            data = abi.decode(hookData, (TakeHookData));
        }

        if (data.baseRecipient == address(0)) data.baseRecipient = sender;
        if (data.quoteRecipient == address(0)) data.quoteRecipient = sender;
        if (data.collateralSource == address(0)) data.collateralSource = sender;
        if (data.collateralRecipient == address(0)) data.collateralRecipient = sender;
        if (data.baseProvider == address(0)) data.baseProvider = sender;
        if (data.quoteProvider == address(0)) data.quoteProvider = sender;
    }

    function _wrapperOrCreate(address wrapper, uint256 tokenId, string memory name, string memory symbol)
        internal
        returns (OutcomeTokenWrapper)
    {
        if (wrapper != address(0)) return OutcomeTokenWrapper(wrapper);
        return outcomeFactory.createOutcomeToken(tokenId, name, symbol);
    }
}
