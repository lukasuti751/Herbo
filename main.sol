// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Wellness ledger for on-chain herb and remedy attestations. Deploy on any EVM chain;
 * curator, treasury and wellness keeper are fixed at deployment. Vitality points
 * are credited by the curator; optional wei donation supports the treasury.
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/Pausable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

contract Herbo is ReentrancyGuard, Pausable, Ownable {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event HerbLogged(
        uint256 indexed entryId,
        address indexed contributor,
        bytes32 nameHash,
        bytes32 benefitHash,
        bytes32 indexed categoryHash,
        uint256 loggedAtBlock,
        uint256 optionalWei
    );
    event HerbEntryUpdated(
        uint256 indexed entryId,
        bytes32 previousBenefitHash,
        bytes32 newBenefitHash,
        uint256 atBlock
    );
    event VitalityCredited(
        address indexed recipient,
        uint256 amount,
        uint256 totalVitality,
        uint256 atBlock
    );
    event VitalitySpent(
        address indexed account,
        uint256 amount,
        bytes32 indexed reasonHash,
        uint256 atBlock
    );
    event CategoryRegistered(
        bytes32 indexed categoryHash,
        bytes32 labelHash,
        address indexed registeredBy,
        uint256 atBlock
    );
    event CategoryLabelChanged(
        bytes32 indexed categoryHash,
        bytes32 previousLabel,
        bytes32 newLabel,
        uint256 atBlock
    );
    event DonationReceived(
        address indexed from,
        uint256 amountWei,
        uint256 entryId,
        uint256 atBlock
    );
    event TreasurySwept(uint256 amountWei, address indexed to, uint256 atBlock);
    event LedgerPaused(bool paused, uint256 atBlock);
    event VitalityRateSet(uint256 previousPerEntry, uint256 newPerEntry, uint256 atBlock);
    event BatchHerbsLogged(uint256[] entryIds, address indexed contributor, uint256 atBlock);
    event BatchVitalityCredited(address[] recipients, uint256[] amounts, uint256 atBlock);
    event KeeperEntryRemoved(uint256 indexed entryId, address indexed removedBy, uint256 atBlock);
    event WellnessNoteAttached(uint256 indexed entryId, bytes32 noteHash, uint256 atBlock);
    event RemedyLogged(uint256 indexed remedyId, address indexed author, bytes32 titleHash, uint256 herbEntryIdRef, uint256 atBlock);
    event RemedyRemoved(uint256 indexed remedyId, address indexed removedBy, uint256 atBlock);
    event RemedyTitleUpdated(uint256 indexed remedyId, bytes32 previousTitle, bytes32 newTitle, uint256 atBlock);
    event BatchRemediesLogged(uint256[] remedyIds, address indexed author, uint256 atBlock);
    event CampaignCreated(uint256 indexed campaignId, uint256 startBlock, uint256 endBlock, address indexed createdBy, uint256 atBlock);
    event EntryJoinedCampaign(uint256 indexed entryId, uint256 indexed campaignId, uint256 atBlock);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error HRB_ZeroAddress();
    error HRB_ZeroEntryId();
    error HRB_EntryNotFound();
    error HRB_InvalidNameHash();
    error HRB_InvalidBenefitHash();
    error HRB_InvalidCategoryHash();
    error HRB_NotCurator();
    error HRB_NotWellnessKeeper();
    error HRB_LedgerPaused();
    error HRB_ReentrantCall();
    error HRB_TransferFailed();
    error HRB_ZeroAmount();
    error HRB_InsufficientVitality();
    error HRB_MaxEntriesReached();
    error HRB_ArrayLengthMismatch();
    error HRB_BatchTooLarge();
    error HRB_ZeroBatchSize();
    error HRB_InvalidVitalityRate();
    error HRB_EntryAlreadyRemoved();
    error HRB_NotEntryContributor();
    error HRB_SameBenefitHash();
    error HRB_MaxCategoriesReached();
    error HRB_CategoryAlreadyExists();
    error HRB_InvalidNoteHash();
    error HRB_RemedyNotFound();
    error HRB_InvalidRemedyRef();
    error HRB_MaxRemediesReached();
    error HRB_NotRemedyAuthor();
    error HRB_RemedyAlreadyRemoved();
    error HRB_InvalidTitleHashForRemedy();
    error HRB_InvalidBlockRange();
    error HRB_CampaignNotFound();
    error HRB_CampaignNotActive();
    error HRB_MaxCampaignsReached();
    error HRB_EntryAlreadyInCampaign();
    error HRB_InvalidCampaignRange();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant HRB_BPS_BASE = 10000;
    uint256 public constant HRB_MAX_FEE_BPS = 500;
    uint256 public constant HRB_MAX_ENTRIES = 2500;
    uint256 public constant HRB_MAX_CATEGORIES = 180;
    uint256 public constant HRB_MAX_BATCH_LOG = 35;
    uint256 public constant HRB_MAX_BATCH_CREDIT = 45;
    uint256 public constant HRB_LEDGER_SALT = 0x8E4a2C6d0F3b5E7a9C1d4F6b8A0c2E5f7B9d1A4;
    uint256 public constant HRB_VITALITY_SCALE = 1e18;

    // -------------------------------------------------------------------------
    // IMMUTABLES
    // -------------------------------------------------------------------------

    address public immutable curator;
    address public immutable treasury;
    address public immutable wellnessKeeper;
    uint256 public immutable deployBlock;
    bytes32 public immutable ledgerDomain;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    struct HerbEntry {
        address contributor;
        bytes32 nameHash;
        bytes32 benefitHash;
        bytes32 categoryHash;
        uint256 loggedAtBlock;
