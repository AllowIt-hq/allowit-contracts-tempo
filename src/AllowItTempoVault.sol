// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITIP20} from "tempo-std/interfaces/ITIP20.sol";
import {StdPrecompiles} from "tempo-std/StdPrecompiles.sol";

/// @notice Funded TIP-20 vault with deterministic limits and exact offchain Jev authorization.
/// @dev Source/requirements digests are provenance, not onchain execution of AllowIt IR.
/// The owner explicitly chooses the evidence authority. No arbitrary calls or token approvals exist.
contract AllowItTempoVault is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Terms {
        bytes32 policyDigest;
        bytes32 requirementsDigest;
        uint256 totalUnits;
        uint256 dailyUnits;
        uint256 actionUnits;
        uint64 expiresAt;
        address recipient; // Zero permits any exact authority-signed, nonzero recipient.
        bool semanticRequired;
    }

    struct Execution {
        uint256 chainId;
        address vault;
        address token;
        bytes32 policyId;
        bytes32 policyDigest;
        bytes32 requirementsDigest;
        uint64 revision;
        uint64 nonce;
        address recipient;
        uint256 amount;
        uint64 expiresAt;
        bytes32 requestHash;
        bytes32 assessmentHash;
        bytes32 memo;
    }

    bytes32 public constant EXECUTION_TYPEHASH = keccak256(
        "Execution(uint256 chainId,address vault,address token,bytes32 policyId,bytes32 policyDigest,bytes32 requirementsDigest,uint64 revision,uint64 nonce,address recipient,uint256 amount,uint64 expiresAt,bytes32 requestHash,bytes32 assessmentHash,bytes32 memo)"
    );
    uint256 public constant MAX_ATTESTATION_TTL = 300;
    address public immutable owner;
    address public immutable executor;
    address public immutable authority;
    ITIP20 public immutable token;
    bytes32 public immutable policyId;
    Terms private _terms;
    uint64 public revision = 1;
    uint64 public nonce;
    uint256 public spent;
    uint256 public spentToday;
    uint256 public spendDay;
    bool public revoked;
    mapping(bytes32 requestHash => bool consumed) public consumedRequests;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidToken();
    error Inactive();
    error Expired();
    error BindingMismatch();
    error Replay();
    error LimitExceeded();
    error InvalidAttestation();
    error DeliveryMismatch();

    event Funded(address indexed owner, uint256 amount);
    event Tuned(uint64 indexed revision, bytes32 policyDigest, bytes32 requirementsDigest);
    event Revoked(address indexed owner);
    event Recovered(address indexed owner, uint256 amount);
    event Executed(
        bytes32 indexed requestHash,
        address indexed recipient,
        uint64 indexed nonce,
        uint64 revision,
        uint256 amount,
        bytes32 assessmentHash,
        bytes32 memo
    );

    constructor(
        address owner_,
        address token_,
        address executor_,
        address authority_,
        bytes32 policyId_,
        Terms memory terms_
    ) EIP712("AllowIt Tempo Vault", "1") {
        if (owner_ == address(0) || executor_ == address(0) || authority_ == address(0) || policyId_ == 0) {
            revert InvalidConfiguration();
        }
        if (!StdPrecompiles.TIP20_FACTORY.isTIP20(token_)) revert InvalidToken();
        if (ITIP20(token_).decimals() != 6 || keccak256(bytes(ITIP20(token_).currency())) != keccak256("USD")) {
            revert InvalidToken();
        }
        owner = owner_;
        executor = executor_;
        authority = authority_;
        token = ITIP20(token_);
        policyId = policyId_;
        _validateTerms(terms_);
        _terms = terms_;
        spendDay = block.timestamp / 1 days;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    function getState()
        external
        view
        returns (
            Terms memory terms,
            uint64 revision_,
            uint64 nonce_,
            uint256 spent_,
            uint256 spentToday_,
            uint256 spendDay_,
            bool revoked_,
            uint256 balance
        )
    {
        return (_terms, revision, nonce, spent, spentToday, spendDay, revoked, token.balanceOf(address(this)));
    }

    /// @notice Owner replenishes liquidity, without replenishing the authorized spend caps.
    function fund(uint256 amount) external onlyOwner nonReentrant {
        if (revoked) revert Inactive();
        if (block.timestamp >= _terms.expiresAt) revert Expired();
        if (amount == 0) revert InvalidConfiguration();
        uint256 beforeBalance = token.balanceOf(address(this));
        IERC20(address(token)).safeTransferFrom(owner, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert DeliveryMismatch();
        emit Funded(owner, amount);
    }

    /// @notice Revise owner-reviewed bindings. Usage/nonces/replay markers never reset.
    function tune(Terms calldata terms_) external onlyOwner nonReentrant {
        if (revoked) revert Inactive();
        _validateTerms(terms_);
        uint256 daySpent = spendDay == block.timestamp / 1 days ? spentToday : 0;
        if (terms_.totalUnits < spent || terms_.dailyUnits < daySpent) revert LimitExceeded();
        _terms = terms_;
        ++revision;
        emit Tuned(revision, terms_.policyDigest, terms_.requirementsDigest);
    }

    function revoke() external onlyOwner nonReentrant {
        _revoke();
    }

    /// @notice Emergency exit belongs only to the owner and permanently disables spending.
    function withdrawRemaining() external onlyOwner nonReentrant {
        _revoke();
        uint256 amount = token.balanceOf(address(this));
        if (amount != 0) _deliver(owner, amount, bytes32(0));
        emit Recovered(owner, amount);
    }

    function executionDigest(Execution calldata request) public view returns (bytes32) {
        // All Execution fields are static ABI types; encode the tuple identically to its flattened fields.
        return _hashTypedDataV4(keccak256(abi.encode(EXECUTION_TYPEHASH, request)));
    }

    function execute(Execution calldata request, bytes calldata authoritySignature) external nonReentrant {
        if (msg.sender != executor) revert Unauthorized();
        if (revoked) revert Inactive();
        Terms memory terms = _terms;
        if (block.timestamp >= terms.expiresAt || block.timestamp >= request.expiresAt) revert Expired();
        if (request.expiresAt > terms.expiresAt || request.expiresAt - block.timestamp > MAX_ATTESTATION_TTL) {
            revert InvalidAttestation();
        }
        if (
            request.chainId != block.chainid || request.vault != address(this) || request.token != address(token)
                || request.policyId != policyId || request.policyDigest != terms.policyDigest
                || request.requirementsDigest != terms.requirementsDigest || request.revision != revision
                || request.recipient == address(0) || request.recipient == address(this)
                || (terms.recipient != address(0) && request.recipient != terms.recipient) || request.requestHash == 0
                || (terms.semanticRequired && request.assessmentHash == 0)
        ) revert BindingMismatch();
        if (nonce == type(uint64).max || request.nonce != nonce + 1 || consumedRequests[request.requestHash]) {
            revert Replay();
        }
        uint256 day = block.timestamp / 1 days;
        uint256 daySpent = day == spendDay ? spentToday : 0;
        if (
            request.amount == 0 || request.amount > terms.actionUnits || request.amount > terms.totalUnits - spent
                || daySpent > terms.dailyUnits || request.amount > terms.dailyUnits - daySpent
        ) revert LimitExceeded();
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(executionDigest(request), authoritySignature);
        if (err != ECDSA.RecoverError.NoError || signer != authority) revert InvalidAttestation();

        // Effects before interaction. A token failure/redirection reverts these changes atomically.
        nonce = request.nonce;
        spent += request.amount;
        spentToday = daySpent + request.amount;
        spendDay = day;
        consumedRequests[request.requestHash] = true;
        _deliver(request.recipient, request.amount, request.memo);
        emit Executed(
            request.requestHash,
            request.recipient,
            request.nonce,
            request.revision,
            request.amount,
            request.assessmentHash,
            request.memo
        );
    }

    function _validateTerms(Terms memory terms) private view {
        if (
            terms.policyDigest == 0 || terms.requirementsDigest == 0 || terms.totalUnits == 0 || terms.dailyUnits == 0
                || terms.actionUnits == 0 || terms.dailyUnits > terms.totalUnits || terms.actionUnits > terms.dailyUnits
                || terms.expiresAt <= block.timestamp || terms.recipient == address(this)
        ) revert InvalidConfiguration();
    }

    function _revoke() private {
        if (!revoked) {
            revoked = true;
            emit Revoked(owner);
        }
    }

    function _deliver(address recipient, uint256 amount, bytes32 memo) private {
        uint256 vaultBefore = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(recipient);
        if (memo == 0) IERC20(address(token)).safeTransfer(recipient, amount);
        else token.transferWithMemo(recipient, amount, memo);
        uint256 vaultAfter = token.balanceOf(address(this));
        uint256 recipientAfter = token.balanceOf(recipient);
        if (
            vaultAfter > vaultBefore || vaultBefore - vaultAfter != amount || recipientAfter < recipientBefore
                || recipientAfter - recipientBefore != amount
        ) revert DeliveryMismatch();
    }
}
