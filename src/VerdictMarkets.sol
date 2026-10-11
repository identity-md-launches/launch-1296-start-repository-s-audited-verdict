// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OracleAttestation} from "./OracleAttestation.sol";
import {IVerdictOracle} from "./interfaces/IVerdictOracle.sol";

/// @notice Immutable parimutuel markets. The guardian controls entry only, never settlement or funds.
contract VerdictMarkets is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        Open,
        Provisional,
        Finalized,
        Voided
    }

    struct Params {
        bytes32 questionHash;
        uint8 answerType;
        uint256 dataChainId;
        uint64 fromBlock;
        uint64 toBlock;
        uint16 minPanelSize;
        uint16 minAgreed;
        uint64 closeAt;
        uint64 answerFrom;
        uint64 answerUntil;
        uint32 disputeWindow;
        uint64 voidAfter;
        uint256[] bounds;
        bytes32[] keys;
        uint256 bounty;
        uint256 settlerReward;
    }

    struct Market {
        Params params;
        address creator;
        bytes32 bodyHash;
        bytes32 escalationBodyHash;
        Status status;
        uint8 outcomes;
        uint8 outcome;
        uint8 asks;
        uint16 panelSize;
        bool escalationAsked;
        bool escalated;
        uint256 lastPrimaryAsk;
        uint256 disputeEnds;
        uint256 pool;
        uint256 bountyRemaining;
        uint256 oracleSpend;
        uint256 fees;
        uint256 returnedBounty;
        uint256 paidOut;
        uint256 refunded;
        uint256 remainingPayout;
        uint256 remainingWinningStake;
        bytes32[2] primaryRequests;
        bytes32 escalationRequest;
        uint256 escalationAskedAt;
        uint256 settlerReward;
        uint256 rewardsPaid;
    }

    error InvalidAddress();
    error InvalidFees();
    error InvalidCap();
    error NotGuardian();
    error NotPendingGuardian();
    error EntryPaused();
    error MustUnpause();
    error MustDisableAllowlist();
    error AllowlistDisabled();
    error CreatorNotAllowed();
    error InvalidParams();
    error InvalidBody();
    error UnknownMarket();
    error WrongState();
    error OutsideWindow();
    error InvalidOutcome();
    error InvalidAmount();
    error PoolCapExceeded();
    error OracleAssetMismatch();
    error InsufficientBounty();
    error AskLimit();
    error RetryNotReady();
    error AnswerAlreadyDelivered();
    error UnauthenticatedAnswer();
    error InvalidAttestation();
    error EscalationUnavailable();
    error NoWinningStake();
    error NothingToClaim();
    error InexactOracleSpend();

    event GuardianTransferStarted(address indexed guardian, address indexed pendingGuardian);
    event GuardianTransferred(address indexed previousGuardian, address indexed newGuardian);
    event PauseChanged(bool paused);
    event CreatorAllowed(address indexed creator, bool allowed);
    event AllowlistTurnedOff();
    event MarketCreated(
        uint256 indexed id,
        address indexed creator,
        bytes32 indexed bodyHash,
        bytes32 escalationBodyHash,
        bytes body,
        bytes escalationBody,
        string uri,
        uint256 agentId
    );
    event BetPlaced(uint256 indexed id, address indexed bettor, uint8 indexed outcome, uint256 amount, uint256 agentId);
    event OracleAsked(uint256 indexed id, bytes32 indexed intakeRequestId, bool escalation, uint256 price);
    event OutcomeProposed(
        uint256 indexed id,
        bytes32 indexed requestId,
        uint8 outcome,
        uint16 panelSize,
        bool escalation,
        uint256 disputeEnds
    );
    event DisputeExtended(uint256 indexed id, uint256 disputeEnds);
    event Finalized(uint256 indexed id, uint8 outcome, uint256 creatorFee, uint256 burnFee, uint256 treasuryFee);
    event Voided(uint256 indexed id);
    event BountyReturned(uint256 indexed id, address indexed creator, uint256 amount);
    event SettlerRewarded(uint256 indexed id, address indexed settler, uint8 action, uint256 amount);
    event Claimed(uint256 indexed id, address indexed bettor, uint256 amount, bool refund);

    IVerdictOracle public immutable oracle;
    IERC20 public immutable collateral;
    address public immutable treasury;
    address public immutable burnSink;
    uint16 public immutable creatorFeeBps;
    uint16 public immutable burnFeeBps;
    uint16 public immutable treasuryFeeBps;
    uint256 public immutable maxPoolPerMarket;
    uint256 public immutable maxSettlerReward;

    address public guardian;
    address public pendingGuardian;
    bool public paused;
    bool public allowlistOn = true;
    mapping(address => bool) public allowedCreators;
    uint256 public marketCount;
    mapping(uint256 => Market) private _markets;
    mapping(uint256 => mapping(uint8 => uint256)) public outcomePool;
    mapping(uint256 => mapping(address => mapping(uint8 => uint256))) public stakes;
    mapping(uint256 => mapping(address => uint256)) public totalStake;
    mapping(uint256 => mapping(address => bool)) public claimed;

    constructor(
        address oracle_,
        address collateral_,
        address treasury_,
        address burnSink_,
        address guardian_,
        uint16 creatorFeeBps_,
        uint16 burnFeeBps_,
        uint16 treasuryFeeBps_,
        uint256 maxPoolPerMarket_,
        uint256 maxSettlerReward_
    ) {
        if (
            oracle_ == address(0) || collateral_ == address(0) || treasury_ == address(0) || burnSink_ == address(0)
                || guardian_ == address(0)
        ) revert InvalidAddress();
        if (uint256(creatorFeeBps_) + burnFeeBps_ + treasuryFeeBps_ > 500) revert InvalidFees();
        if (maxPoolPerMarket_ == 0) revert InvalidCap();
        oracle = IVerdictOracle(oracle_);
        collateral = IERC20(collateral_);
        treasury = treasury_;
        burnSink = burnSink_;
        guardian = guardian_;
        creatorFeeBps = creatorFeeBps_;
        burnFeeBps = burnFeeBps_;
        treasuryFeeBps = treasuryFeeBps_;
        maxPoolPerMarket = maxPoolPerMarket_;
        maxSettlerReward = maxSettlerReward_;
        emit GuardianTransferred(address(0), guardian_);
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    modifier entryOpen() {
        if (paused) revert EntryPaused();
        _;
    }

    function pause() external onlyGuardian {
        if (paused) revert EntryPaused();
        paused = true;
        emit PauseChanged(true);
    }

    function unpause() external onlyGuardian {
        if (!paused) revert WrongState();
        paused = false;
        emit PauseChanged(false);
    }

    function setCreatorAllowed(address creator, bool allowed) external onlyGuardian {
        if (!allowlistOn) revert AllowlistDisabled();
        if (creator == address(0)) revert InvalidAddress();
        allowedCreators[creator] = allowed;
        emit CreatorAllowed(creator, allowed);
    }

    function disableAllowlist() external onlyGuardian {
        if (!allowlistOn) revert AllowlistDisabled();
        allowlistOn = false;
        emit AllowlistTurnedOff();
    }

    function transferGuardian(address next) external onlyGuardian {
        if (next == address(0)) revert InvalidAddress();
        pendingGuardian = next;
        emit GuardianTransferStarted(guardian, next);
    }

    function acceptGuardian() external {
        if (msg.sender != pendingGuardian) revert NotPendingGuardian();
        address previous = guardian;
        guardian = msg.sender;
        pendingGuardian = address(0);
        emit GuardianTransferred(previous, msg.sender);
    }

    function renounceGuardian() external onlyGuardian {
        if (paused) revert MustUnpause();
        if (allowlistOn) revert MustDisableAllowlist();
        address previous = guardian;
        guardian = address(0);
        pendingGuardian = address(0);
        emit GuardianTransferred(previous, address(0));
    }

    function createMarket(
        Params calldata p,
        bytes calldata body,
        bytes calldata escalationBody,
        string calldata uri,
        uint256 agentId
    ) external nonReentrant entryOpen returns (uint256 id) {
        if (allowlistOn && !allowedCreators[msg.sender]) revert CreatorNotAllowed();
        uint8 outcomes = _validateParams(p);
        if (body.length == 0 || body.length > 16_384 || escalationBody.length > 16_384) revert InvalidBody();
        bytes32 bodyHash = keccak256(body);
        bytes32 escalationHash = escalationBody.length == 0 ? bytes32(0) : keccak256(escalationBody);
        if (bodyHash == escalationHash) revert InvalidBody();
        if (oracle.asset() != address(collateral)) revert OracleAssetMismatch();
        uint256 cost = oracle.price();
        _checkBounty(p.bounty, cost, p.settlerReward);
        uint256 received = _pull(msg.sender, p.bounty);
        _checkBounty(received, cost, p.settlerReward);
        id = ++marketCount;
        Market storage m = _markets[id];
        m.params = p;
        m.params.bounty = received;
        m.creator = msg.sender;
        m.bodyHash = bodyHash;
        m.escalationBodyHash = escalationHash;
        m.outcomes = outcomes;
        m.bountyRemaining = received;
        m.settlerReward = p.settlerReward;
        emit MarketCreated(id, msg.sender, bodyHash, escalationHash, body, escalationBody, uri, agentId);
    }

    function bet(uint256 id, uint8 outcome, uint256 amount, uint256 agentId) external nonReentrant entryOpen {
        Market storage m = _market(id);
        if (m.status != Status.Open) revert WrongState();
        if (block.timestamp >= m.params.closeAt) revert OutsideWindow();
        if (outcome >= m.outcomes) revert InvalidOutcome();
        uint256 received = _pull(msg.sender, amount);
        if (received > maxPoolPerMarket - m.pool) revert PoolCapExceeded();
        m.pool += received;
        outcomePool[id][outcome] += received;
        stakes[id][msg.sender][outcome] += received;
        totalStake[id][msg.sender] += received;
        emit BetPlaced(id, msg.sender, outcome, received, agentId);
    }

    function resolve(uint256 id, bytes calldata body) external nonReentrant returns (bytes32 requestId) {
        Market storage m = _market(id);
        if (m.status != Status.Open) revert WrongState();
        _askWindow(m);
        if (keccak256(body) != m.bodyHash) revert InvalidBody();
        if (m.asks >= 2) revert AskLimit();
        if (m.asks != 0) {
            if (block.timestamp < m.lastPrimaryAsk + 24 hours) revert RetryNotReady();
            if (!oracle.hasPendingRequest(m.primaryRequests[0])) revert AnswerAlreadyDelivered();
        }
        m.lastPrimaryAsk = block.timestamp;
        requestId = _ask(id, m, body, false);
        _pay(msg.sender, _recordSettlerReward(id, m, 0));
    }

    function escalate(uint256 id, bytes calldata body) external nonReentrant returns (bytes32 requestId) {
        Market storage m = _market(id);
        if (m.status != Status.Provisional || m.escalated) revert WrongState();
        _askWindow(m);
        if (block.timestamp >= m.disputeEnds) revert OutsideWindow();
        if (m.escalationAsked || m.escalationBodyHash == bytes32(0)) revert EscalationUnavailable();
        if (keccak256(body) != m.escalationBodyHash) revert InvalidBody();
        if (m.asks >= 2) revert AskLimit();
        m.escalationAsked = true;
        m.escalationAskedAt = block.timestamp;
        m.disputeEnds = Math.max(m.disputeEnds, block.timestamp + 24 hours);
        emit DisputeExtended(id, m.disputeEnds);
        requestId = _ask(id, m, body, true);
    }

    function propose(uint256 id, OracleAttestation.Attestation calldata a) external nonReentrant {
        Market storage m = _market(id);
        bool replacement = m.status == Status.Provisional;
        if (m.status != Status.Open && !replacement) revert WrongState();
        if (block.timestamp < m.params.answerFrom) revert OutsideWindow();
        if (replacement) {
            if (m.escalated || m.escalationBodyHash == bytes32(0)) revert EscalationUnavailable();
            if (block.timestamp >= m.disputeEnds) revert OutsideWindow();
            if (uint256(a.panelSize) < uint256(m.panelSize) * 2) revert InvalidAttestation();
        } else if (block.timestamp >= m.params.voidAfter) {
            revert OutsideWindow();
        }
        bytes32 expected = replacement ? m.escalationBodyHash : m.bodyHash;
        if (oracle.answerOf(a) != expected) revert UnauthenticatedAnswer();
        bytes32 intakeRequestId = oracle.intakeRequestOf(a.requestId);
        if (replacement) {
            if (!m.escalationAsked || intakeRequestId != m.escalationRequest) revert UnauthenticatedAnswer();
        } else if (
            m.asks == 0
                || (intakeRequestId != m.primaryRequests[0] && (m.asks < 2 || intakeRequestId != m.primaryRequests[1]))
        ) {
            revert UnauthenticatedAnswer();
        }
        Params storage p = m.params;
        if (
            a.questionHash != p.questionHash || a.answerType != p.answerType || a.chainId != p.dataChainId
                || a.fromBlock != p.fromBlock || a.toBlock != p.toBlock || a.panelSize < p.minPanelSize
                || a.agreed < p.minAgreed || a.agreed < a.quorum || a.agreed > a.panelSize || a.quorum == 0
                || a.issuedAt < (replacement ? m.escalationAskedAt : p.answerFrom)
                || a.issuedAt > (replacement ? m.disputeEnds : p.answerUntil)
        ) {
            revert InvalidAttestation();
        }
        m.outcome = _outcome(p, a.answer);
        m.panelSize = a.panelSize;
        m.status = Status.Provisional;
        m.escalated = replacement;
        // A replacement restarts a full dispute window exactly once.
        m.disputeEnds = block.timestamp + p.disputeWindow;
        emit OutcomeProposed(id, a.requestId, m.outcome, a.panelSize, replacement, m.disputeEnds);
        _pay(msg.sender, _recordSettlerReward(id, m, 1));
    }

    function finalize(uint256 id) external nonReentrant {
        Market storage m = _market(id);
        if (m.status != Status.Provisional) revert WrongState();
        if (block.timestamp < m.disputeEnds) revert OutsideWindow();
        uint256 winningPool = outcomePool[id][m.outcome];
        if (winningPool == 0) revert NoWinningStake();
        uint256 creatorFee = Math.mulDiv(m.pool, creatorFeeBps, 10_000);
        uint256 burnFee = Math.mulDiv(m.pool, burnFeeBps, 10_000);
        uint256 treasuryFee = Math.mulDiv(m.pool, treasuryFeeBps, 10_000);
        m.status = Status.Finalized;
        m.fees = creatorFee + burnFee + treasuryFee;
        m.remainingPayout = m.pool - m.fees;
        m.remainingWinningStake = winningPool;
        uint256 reward = _recordSettlerReward(id, m, 2);
        uint256 bounty = _releaseBounty(id, m);
        emit Finalized(id, m.outcome, creatorFee, burnFee, treasuryFee);
        _pay(msg.sender, reward);
        _pay(m.creator, creatorFee + bounty);
        _pay(burnSink, burnFee);
        _pay(treasury, treasuryFee);
    }

    function voidMarket(uint256 id) external nonReentrant {
        Market storage m = _market(id);
        if (m.status == Status.Open) {
            if (block.timestamp < m.params.voidAfter) revert OutsideWindow();
        } else if (m.status == Status.Provisional) {
            // A primary outcome can still be replaced; never void it during the dispute window.
            if (block.timestamp < m.disputeEnds) revert OutsideWindow();
            if (outcomePool[id][m.outcome] != 0) revert WrongState();
        } else {
            revert WrongState();
        }
        m.status = Status.Voided;
        uint256 reward = _recordSettlerReward(id, m, 3);
        uint256 bounty = _releaseBounty(id, m);
        emit Voided(id);
        _pay(msg.sender, reward);
        _pay(m.creator, bounty);
    }

    /// @notice Winners claim payouts; after voiding, every bettor claims their full credited deposits.
    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        Market storage m = _market(id);
        if (claimed[id][msg.sender]) revert NothingToClaim();
        bool refund = m.status == Status.Voided;
        if (refund) {
            amount = totalStake[id][msg.sender];
            if (amount == 0) revert NothingToClaim();
            m.refunded += amount;
        } else {
            if (m.status != Status.Finalized) revert WrongState();
            uint256 stake = stakes[id][msg.sender][m.outcome];
            if (stake == 0) revert NothingToClaim();
            amount = stake == m.remainingWinningStake
                ? m.remainingPayout
                : Math.mulDiv(stake, m.pool - m.fees, outcomePool[id][m.outcome]);
            m.remainingWinningStake -= stake;
            m.remainingPayout -= amount;
            m.paidOut += amount;
        }
        claimed[id][msg.sender] = true;
        emit Claimed(id, msg.sender, amount, refund);
        _pay(msg.sender, amount);
    }

    function getMarket(uint256 id) external view returns (Market memory) {
        return _market(id);
    }

    function _market(uint256 id) private view returns (Market storage m) {
        m = _markets[id];
        if (m.creator == address(0)) revert UnknownMarket();
    }

    function _askWindow(Market storage m) private view {
        if (block.timestamp < m.params.answerFrom || block.timestamp >= m.params.answerUntil) revert OutsideWindow();
    }

    function _ask(uint256 id, Market storage m, bytes calldata body, bool escalation)
        private
        returns (bytes32 requestId)
    {
        if (oracle.asset() != address(collateral)) revert OracleAssetMismatch();
        uint256 cost = oracle.price();
        if (cost > m.bountyRemaining) revert InsufficientBounty();
        m.asks++;
        m.bountyRemaining -= cost;
        m.oracleSpend += cost;
        uint256 beforeBalance = collateral.balanceOf(address(this));
        collateral.forceApprove(address(oracle), cost);
        requestId = oracle.request(body);
        collateral.forceApprove(address(oracle), 0);
        if (collateral.balanceOf(address(this)) != beforeBalance - cost) revert InexactOracleSpend();
        if (escalation) m.escalationRequest = requestId;
        else m.primaryRequests[m.asks - 1] = requestId;
        emit OracleAsked(id, requestId, escalation, cost);
    }

    /// @dev Account before transferring. Terminal calls release bounty only after this deduction.
    function _recordSettlerReward(uint256 id, Market storage m, uint8 action) private returns (uint256 amount) {
        if (m.settlerReward == 0) return 0;
        uint256 reserve;
        // Resolve and accepted proposals have already used at least one ask. With asks < 2,
        // exactly one remains. Read its price now, including changes since creation or the ask.
        if (action < 2 && m.asks < 2) reserve = oracle.price();
        if (m.bountyRemaining > reserve) amount = Math.min(m.settlerReward, m.bountyRemaining - reserve);
        m.bountyRemaining -= amount;
        m.rewardsPaid += amount;
        emit SettlerRewarded(id, msg.sender, action, amount);
    }

    function _checkBounty(uint256 bounty, uint256 cost, uint256 reward) private pure {
        // Equivalent to bounty >= 2 * cost + 5 * reward without overflowing either product or sum.
        if (bounty / 2 < cost || (bounty - 2 * cost) / 5 < reward) revert InsufficientBounty();
    }

    function _releaseBounty(uint256 id, Market storage m) private returns (uint256 bounty) {
        bounty = m.bountyRemaining;
        m.bountyRemaining = 0;
        m.returnedBounty = bounty;
        emit BountyReturned(id, m.creator, bounty);
    }

    function _pull(address from, uint256 amount) private returns (uint256 received) {
        if (amount == 0) revert InvalidAmount();
        uint256 beforeBalance = collateral.balanceOf(address(this));
        collateral.safeTransferFrom(from, address(this), amount);
        received = collateral.balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert InvalidAmount();
    }

    function _pay(address to, uint256 amount) private {
        if (amount != 0) collateral.safeTransfer(to, amount);
    }

    function _validateParams(Params calldata p) private view returns (uint8 outcomes) {
        if (
            p.questionHash == bytes32(0) || p.dataChainId == 0 || p.fromBlock > p.toBlock || p.minPanelSize < 5
                || p.minAgreed == 0 || p.closeAt <= block.timestamp || p.closeAt > p.answerFrom
                || p.answerFrom >= p.answerUntil || p.answerUntil >= p.voidAfter || p.disputeWindow < 1 hours
                || p.disputeWindow > 3 days || p.settlerReward > maxSettlerReward
        ) {
            revert InvalidParams();
        }
        if (p.answerType == 0) {
            if (p.bounds.length != 0 || p.keys.length != 0) revert InvalidParams();
            return 2;
        }
        if (p.answerType == 3) {
            if (p.bounds.length == 0 || p.bounds.length > 7 || p.keys.length != 0) revert InvalidParams();
            if (p.bounds[0] == 0) revert InvalidParams();
            for (uint256 i = 1; i < p.bounds.length; i++) {
                if (p.bounds[i] <= p.bounds[i - 1]) revert InvalidParams();
            }
            return uint8(p.bounds.length + 1);
        }
        if (p.answerType == 4 || p.answerType == 5) {
            if (p.keys.length == 0 || p.keys.length > 7 || p.bounds.length != 0) revert InvalidParams();
            for (uint256 i; i < p.keys.length; i++) {
                if (p.answerType == 4 && uint256(p.keys[i]) > type(uint160).max) revert InvalidParams();
                for (uint256 j; j < i; j++) {
                    if (p.keys[i] == p.keys[j]) revert InvalidParams();
                }
            }
            return uint8(p.keys.length + 1);
        }
        revert InvalidParams();
    }

    function _outcome(Params storage p, bytes calldata answer) private view returns (uint8) {
        if (p.answerType == 0) return abi.decode(answer, (bool)) ? 1 : 0;
        if (p.answerType == 3) {
            uint256 value = abi.decode(answer, (uint256));
            for (uint8 i; i < p.bounds.length; i++) {
                if (value < p.bounds[i]) return i;
            }
            return uint8(p.bounds.length);
        }
        bytes32 first;
        bool empty;
        if (p.answerType == 4) {
            address[] memory values = abi.decode(answer, (address[]));
            empty = values.length == 0;
            if (!empty) first = bytes32(uint256(uint160(values[0])));
        } else {
            bytes32[] memory values = abi.decode(answer, (bytes32[]));
            empty = values.length == 0;
            if (!empty) first = values[0];
        }
        if (!empty) {
            for (uint8 i; i < p.keys.length; i++) {
                if (first == p.keys[i]) return i;
            }
        }
        return uint8(p.keys.length);
    }
}
