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
        uint256 optionalWei;
        bool active;
        bytes32 noteHash;
    }

    struct CategoryInfo {
        bytes32 labelHash;
        uint256 entryCount;
        uint256 registeredAtBlock;
        bool exists;
    }

    uint256 public entryCounter;
    uint256 public categoryCounter;
    uint256 public vitalityPerEntry;
    uint256 public donationFeeBps;
    bool public ledgerPaused;

    mapping(uint256 => HerbEntry) public herbEntries;
    mapping(bytes32 => CategoryInfo) public categories;
    mapping(address => uint256) public vitalityBalance;
    mapping(address => uint256[]) private _entryIdsByContributor;
    mapping(bytes32 => uint256[]) private _entryIdsByCategory;
    uint256[] private _allEntryIds;
    bytes32[] private _categoryHashes;
    uint256 private _treasuryAccum;
    uint256 private _reentrancyLock;

    uint256 public remedyCounter;
    uint256 public constant HRB_MAX_REMEDIES = 1200;
    uint256 public constant HRB_MAX_REMEDY_BATCH = 28;
    struct Remedy {
        address author;
        bytes32 titleHash;
        uint256 herbEntryIdRef;
        uint256 createdAtBlock;
        bool active;
    }
    mapping(uint256 => Remedy) public remedies;
    uint256[] private _remedyIds;
    mapping(address => uint256[]) private _remedyIdsByAuthor;
    mapping(bytes32 => uint256[]) private _remedyIdsByTitle;

    uint256 public campaignCounter;
    uint256 public constant HRB_MAX_CAMPAIGNS = 95;
    struct Campaign {
        uint256 startBlock;
        uint256 endBlock;
        uint256 entryCount;
        bool exists;
    }
    mapping(uint256 => Campaign) public campaigns;
    mapping(uint256 => uint256[]) private _campaignEntryIds;
    mapping(uint256 => uint256) private _entryToCampaign;

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier whenLedgerNotPaused() {
        if (ledgerPaused) revert HRB_LedgerPaused();
        _;
    }

    modifier onlyCurator() {
        if (msg.sender != curator) revert HRB_NotCurator();
        _;
    }

    modifier onlyWellnessKeeper() {
        if (msg.sender != wellnessKeeper) revert HRB_NotWellnessKeeper();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert HRB_ReentrantCall();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        curator = address(0x3E7a9C2d4F6b8A0c2E4f6A8b0C2d4E6f8A0b2C4d6);
        treasury = address(0x5B9d1F3a5C7e9B1d3F5a7C9e1B3d5F7a9C1e3B5d7);
        wellnessKeeper = address(0x7C0e2A4b6D8f0B2d4F6a8C0e2B4d6F8a0C2e4B6f8);
        deployBlock = block.number;
        ledgerDomain = keccak256(abi.encodePacked("Herbo_Ledger", block.chainid, block.prevrandao, HRB_LEDGER_SALT));
        if (curator == address(0) || treasury == address(0) || wellnessKeeper == address(0)) revert HRB_ZeroAddress();
        vitalityPerEntry = 100 * HRB_VITALITY_SCALE;
        donationFeeBps = 80;
    }

    // -------------------------------------------------------------------------
    // ADMIN
    // -------------------------------------------------------------------------

    function setLedgerPaused(bool paused) external onlyOwner {
        ledgerPaused = paused;
        emit LedgerPaused(paused, block.number);
    }

    function setVitalityPerEntry(uint256 newVitalityPerEntry) external onlyOwner {
        uint256 prev = vitalityPerEntry;
        vitalityPerEntry = newVitalityPerEntry;
        emit VitalityRateSet(prev, newVitalityPerEntry, block.number);
    }

    function setDonationFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > HRB_MAX_FEE_BPS) revert HRB_InvalidVitalityRate();
        donationFeeBps = newFeeBps;
    }

    // -------------------------------------------------------------------------
    // CATEGORY REGISTRATION
    // -------------------------------------------------------------------------

    function registerCategory(bytes32 categoryHash, bytes32 labelHash) external onlyCurator whenLedgerNotPaused {
        if (categoryHash == bytes32(0)) revert HRB_InvalidCategoryHash();
        if (categories[categoryHash].exists) revert HRB_CategoryAlreadyExists();
        if (categoryCounter >= HRB_MAX_CATEGORIES) revert HRB_MaxCategoriesReached();
        categoryCounter++;
        _categoryHashes.push(categoryHash);
        categories[categoryHash] = CategoryInfo({
            labelHash: labelHash,
            entryCount: 0,
            registeredAtBlock: block.number,
            exists: true
        });
        emit CategoryRegistered(categoryHash, labelHash, msg.sender, block.number);
    }

    function updateCategoryLabel(bytes32 categoryHash, bytes32 newLabelHash) external onlyCurator {
        if (!categories[categoryHash].exists) revert HRB_EntryNotFound();
        bytes32 prev = categories[categoryHash].labelHash;
        categories[categoryHash].labelHash = newLabelHash;
        emit CategoryLabelChanged(categoryHash, prev, newLabelHash, block.number);
    }

    // -------------------------------------------------------------------------
    // LOG HERB (SINGLE)
    // -------------------------------------------------------------------------

    function logHerb(
        bytes32 nameHash,
        bytes32 benefitHash,
        bytes32 categoryHash,
        uint256 optionalWei
    ) external payable nonReentrant whenLedgerNotPaused returns (uint256 entryId) {
        if (nameHash == bytes32(0)) revert HRB_InvalidNameHash();
        if (benefitHash == bytes32(0)) revert HRB_InvalidBenefitHash();
        if (!categories[categoryHash].exists) revert HRB_EntryNotFound();
        if (entryCounter >= HRB_MAX_ENTRIES) revert HRB_MaxEntriesReached();
        if (msg.value != optionalWei) revert HRB_ZeroAmount();

        entryId = ++entryCounter;
        uint256 feeWei = (optionalWei * donationFeeBps) / HRB_BPS_BASE;
        uint256 toTreasury = feeWei;
        _treasuryAccum += toTreasury;

        herbEntries[entryId] = HerbEntry({
            contributor: msg.sender,
            nameHash: nameHash,
            benefitHash: benefitHash,
            categoryHash: categoryHash,
            loggedAtBlock: block.number,
            optionalWei: optionalWei,
            active: true,
            noteHash: bytes32(0)
        });

        _entryIdsByContributor[msg.sender].push(entryId);
        _entryIdsByCategory[categoryHash].push(entryId);
        _allEntryIds.push(entryId);
        categories[categoryHash].entryCount++;

        emit HerbLogged(entryId, msg.sender, nameHash, benefitHash, categoryHash, block.number, optionalWei);
        if (optionalWei > 0) emit DonationReceived(msg.sender, optionalWei, entryId, block.number);
    }

    function logHerbFree(
        bytes32 nameHash,
        bytes32 benefitHash,
        bytes32 categoryHash
    ) external nonReentrant whenLedgerNotPaused returns (uint256 entryId) {
        if (nameHash == bytes32(0)) revert HRB_InvalidNameHash();
        if (benefitHash == bytes32(0)) revert HRB_InvalidBenefitHash();
        if (!categories[categoryHash].exists) revert HRB_EntryNotFound();
        if (entryCounter >= HRB_MAX_ENTRIES) revert HRB_MaxEntriesReached();

        entryId = ++entryCounter;
        herbEntries[entryId] = HerbEntry({
            contributor: msg.sender,
            nameHash: nameHash,
            benefitHash: benefitHash,
            categoryHash: categoryHash,
            loggedAtBlock: block.number,
            optionalWei: 0,
            active: true,
            noteHash: bytes32(0)
        });

        _entryIdsByContributor[msg.sender].push(entryId);
        _entryIdsByCategory[categoryHash].push(entryId);
        _allEntryIds.push(entryId);
        categories[categoryHash].entryCount++;

        emit HerbLogged(entryId, msg.sender, nameHash, benefitHash, categoryHash, block.number, 0);
    }

    // -------------------------------------------------------------------------
    // BATCH LOG
    // -------------------------------------------------------------------------

    function batchLogHerbs(
        bytes32[] calldata nameHashes,
        bytes32[] calldata benefitHashes,
        bytes32[] calldata categoryHashes
    ) external nonReentrant whenLedgerNotPaused returns (uint256[] memory entryIds) {
        uint256 n = nameHashes.length;
        if (n != benefitHashes.length || n != categoryHashes.length) revert HRB_ArrayLengthMismatch();
        if (n == 0) revert HRB_ZeroBatchSize();
        if (n > HRB_MAX_BATCH_LOG) revert HRB_BatchTooLarge();
        if (entryCounter + n > HRB_MAX_ENTRIES) revert HRB_MaxEntriesReached();

        entryIds = new uint256[](n);
        for (uint256 i; i < n;) {
            if (nameHashes[i] == bytes32(0)) revert HRB_InvalidNameHash();
            if (benefitHashes[i] == bytes32(0)) revert HRB_InvalidBenefitHash();
            if (!categories[categoryHashes[i]].exists) revert HRB_EntryNotFound();

            uint256 entryId = ++entryCounter;
            herbEntries[entryId] = HerbEntry({
                contributor: msg.sender,
                nameHash: nameHashes[i],
                benefitHash: benefitHashes[i],
                categoryHash: categoryHashes[i],
                loggedAtBlock: block.number,
                optionalWei: 0,
                active: true,
                noteHash: bytes32(0)
            });
            entryIds[i] = entryId;
            _entryIdsByContributor[msg.sender].push(entryId);
            _entryIdsByCategory[categoryHashes[i]].push(entryId);
            _allEntryIds.push(entryId);
            categories[categoryHashes[i]].entryCount++;
            emit HerbLogged(entryId, msg.sender, nameHashes[i], benefitHashes[i], categoryHashes[i], block.number, 0);
            unchecked { ++i; }
        }
        emit BatchHerbsLogged(entryIds, msg.sender, block.number);
    }

    // -------------------------------------------------------------------------
    // UPDATE ENTRY (CONTRIBUTOR)
    // -------------------------------------------------------------------------

    function updateHerbBenefit(uint256 entryId, bytes32 newBenefitHash) external {
        if (entryId == 0 || entryId > entryCounter) revert HRB_EntryNotFound();
        HerbEntry storage e = herbEntries[entryId];
        if (!e.active) revert HRB_EntryAlreadyRemoved();
        if (e.contributor != msg.sender) revert HRB_NotEntryContributor();
        if (newBenefitHash == bytes32(0)) revert HRB_InvalidBenefitHash();
        if (newBenefitHash == e.benefitHash) revert HRB_SameBenefitHash();
        bytes32 prev = e.benefitHash;
        e.benefitHash = newBenefitHash;
        emit HerbEntryUpdated(entryId, prev, newBenefitHash, block.number);
    }

    function attachWellnessNote(uint256 entryId, bytes32 noteHash) external {
        if (entryId == 0 || entryId > entryCounter) revert HRB_EntryNotFound();
        HerbEntry storage e = herbEntries[entryId];
        if (!e.active) revert HRB_EntryAlreadyRemoved();
        if (e.contributor != msg.sender) revert HRB_NotEntryContributor();
        if (noteHash == bytes32(0)) revert HRB_InvalidNoteHash();
        e.noteHash = noteHash;
        emit WellnessNoteAttached(entryId, noteHash, block.number);
    }

    // -------------------------------------------------------------------------
    // VITALITY (CURATOR CREDITS)
    // -------------------------------------------------------------------------

    function creditVitality(address recipient, uint256 amount) external onlyCurator nonReentrant {
        if (recipient == address(0)) revert HRB_ZeroAddress();
        if (amount == 0) revert HRB_ZeroAmount();
        vitalityBalance[recipient] += amount;
        emit VitalityCredited(recipient, amount, vitalityBalance[recipient], block.number);
    }

    function batchCreditVitality(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyCurator nonReentrant {
        uint256 n = recipients.length;
        if (n != amounts.length) revert HRB_ArrayLengthMismatch();
        if (n == 0) revert HRB_ZeroBatchSize();
        if (n > HRB_MAX_BATCH_CREDIT) revert HRB_BatchTooLarge();
        for (uint256 i; i < n;) {
            if (recipients[i] != address(0) && amounts[i] > 0) {
                vitalityBalance[recipients[i]] += amounts[i];
                emit VitalityCredited(recipients[i], amounts[i], vitalityBalance[recipients[i]], block.number);
            }
            unchecked { ++i; }
        }
        emit BatchVitalityCredited(recipients, amounts, block.number);
    }

    function creditVitalityForEntry(uint256 entryId) external onlyCurator nonReentrant {
        if (entryId == 0 || entryId > entryCounter) revert HRB_EntryNotFound();
        HerbEntry storage e = herbEntries[entryId];
        if (!e.active) revert HRB_EntryAlreadyRemoved();
        address recipient = e.contributor;
        vitalityBalance[recipient] += vitalityPerEntry;
        emit VitalityCredited(recipient, vitalityPerEntry, vitalityBalance[recipient], block.number);
    }

    function creditVitalityForEntries(uint256[] calldata entryIds) external onlyCurator nonReentrant {
        for (uint256 i; i < entryIds.length;) {
            uint256 entryId = entryIds[i];
            if (entryId != 0 && entryId <= entryCounter) {
                HerbEntry storage e = herbEntries[entryId];
                if (e.active) {
                    vitalityBalance[e.contributor] += vitalityPerEntry;
                    emit VitalityCredited(e.contributor, vitalityPerEntry, vitalityBalance[e.contributor], block.number);
                }
            }
            unchecked { ++i; }
        }
    }

    // -------------------------------------------------------------------------
    // SPEND VITALITY (OPTIONAL MECHANIC)
    // -------------------------------------------------------------------------

    function spendVitality(uint256 amount, bytes32 reasonHash) external nonReentrant {
        if (amount == 0) revert HRB_ZeroAmount();
        if (vitalityBalance[msg.sender] < amount) revert HRB_InsufficientVitality();
        vitalityBalance[msg.sender] -= amount;
        emit VitalitySpent(msg.sender, amount, reasonHash, block.number);
    }

    // -------------------------------------------------------------------------
    // KEEPER (REMOVE ENTRY)
    // -------------------------------------------------------------------------

    function keeperRemoveEntry(uint256 entryId) external onlyWellnessKeeper {
        if (entryId == 0 || entryId > entryCounter) revert HRB_EntryNotFound();
        HerbEntry storage e = herbEntries[entryId];
        if (!e.active) revert HRB_EntryAlreadyRemoved();
        e.active = false;
        if (categories[e.categoryHash].entryCount > 0) categories[e.categoryHash].entryCount--;
        emit KeeperEntryRemoved(entryId, msg.sender, block.number);
    }

    // -------------------------------------------------------------------------
    // CAMPAIGNS
    // -------------------------------------------------------------------------

    function createCampaign(uint256 startBlock, uint256 endBlock) external onlyCurator returns (uint256 campaignId) {
        if (startBlock >= endBlock) revert HRB_InvalidCampaignRange();
        if (campaignCounter >= HRB_MAX_CAMPAIGNS) revert HRB_MaxCampaignsReached();
        campaignId = ++campaignCounter;
        campaigns[campaignId] = Campaign({
            startBlock: startBlock,
            endBlock: endBlock,
            entryCount: 0,
            exists: true
        });
        emit CampaignCreated(campaignId, startBlock, endBlock, msg.sender, block.number);
    }

    function joinEntryToCampaign(uint256 entryId, uint256 campaignId) external {
        if (entryId == 0 || entryId > entryCounter) revert HRB_EntryNotFound();
        if (campaignId == 0 || campaignId > campaignCounter) revert HRB_CampaignNotFound();
        HerbEntry storage e = herbEntries[entryId];
        if (!e.active) revert HRB_EntryAlreadyRemoved();
        if (e.contributor != msg.sender) revert HRB_NotEntryContributor();
        if (_entryToCampaign[entryId] != 0) revert HRB_EntryAlreadyInCampaign();
        Campaign storage c = campaigns[campaignId];
        if (!c.exists) revert HRB_CampaignNotFound();
        if (block.number < c.startBlock || block.number > c.endBlock) revert HRB_CampaignNotActive();
        _entryToCampaign[entryId] = campaignId;
        _campaignEntryIds[campaignId].push(entryId);
        c.entryCount++;
        emit EntryJoinedCampaign(entryId, campaignId, block.number);
    }

    function getCampaign(uint256 campaignId) external view returns (
        uint256 startBlock,
        uint256 endBlock,
        uint256 entryCount,
        bool exists
    ) {
        if (campaignId == 0 || campaignId > campaignCounter) revert HRB_CampaignNotFound();
        Campaign storage c = campaigns[campaignId];
        return (c.startBlock, c.endBlock, c.entryCount, c.exists);
    }

    function getCampaignEntryIds(uint256 campaignId) external view returns (uint256[] memory) {
        if (campaignId == 0 || campaignId > campaignCounter) revert HRB_CampaignNotFound();
        return _campaignEntryIds[campaignId];
    }

    function getEntryCampaign(uint256 entryId) external view returns (uint256 campaignId) {
        if (entryId == 0 || entryId > entryCounter) revert HRB_EntryNotFound();
        return _entryToCampaign[entryId];
    }

    function isCampaignActive(uint256 campaignId) external view returns (bool) {
        if (campaignId == 0 || campaignId > campaignCounter) return false;
        Campaign storage c = campaigns[campaignId];
        return c.exists && block.number >= c.startBlock && block.number <= c.endBlock;
    }

    // -------------------------------------------------------------------------
    // TREASURY
    // -------------------------------------------------------------------------

    function sweepTreasury() external nonReentrant {
        uint256 amount = _treasuryAccum;
        if (amount == 0) return;
        _treasuryAccum = 0;
        (bool ok,) = treasury.call{value: amount}("");
        if (!ok) revert HRB_TransferFailed();
        emit TreasurySwept(amount, treasury, block.number);
    }

    function withdrawExcessToTreasury(uint256 amountWei) external onlyOwner nonReentrant {
        if (amountWei == 0) revert HRB_ZeroAmount();
        uint256 bal = address(this).balance;
        uint256 reserved = _treasuryAccum;
        if (bal <= reserved) return;
        uint256 available = bal - reserved;
        if (amountWei > available) amountWei = available;
        (bool ok,) = treasury.call{value: amountWei}("");
        if (!ok) revert HRB_TransferFailed();
        emit TreasurySwept(amountWei, treasury, block.number);
    }

    // -------------------------------------------------------------------------
    // VIEWS
    // -------------------------------------------------------------------------

    function getEntry(uint256 entryId) external view returns (
        address contributor,
        bytes32 nameHash,
        bytes32 benefitHash,
        bytes32 categoryHash,
        uint256 loggedAtBlock,
        uint256 optionalWei,
        bool active,
        bytes32 noteHash
    ) {
        if (entryId == 0 || entryId > entryCounter) revert HRB_EntryNotFound();
        HerbEntry storage e = herbEntries[entryId];
        return (
            e.contributor,
            e.nameHash,
            e.benefitHash,
            e.categoryHash,
            e.loggedAtBlock,
            e.optionalWei,
            e.active,
            e.noteHash
        );
    }

    function getEntryIds() external view returns (uint256[] memory) {
        return _allEntryIds;
    }

    function getEntryIdsByContributor(address contributor) external view returns (uint256[] memory) {
        return _entryIdsByContributor[contributor];
    }

    function getEntryIdsByCategory(bytes32 categoryHash) external view returns (uint256[] memory) {
        return _entryIdsByCategory[categoryHash];
    }

    function getCategoryHashes() external view returns (bytes32[] memory) {
        return _categoryHashes;
    }

    function getCategoryInfo(bytes32 categoryHash) external view returns (
        bytes32 labelHash,
        uint256 entryCount,
        uint256 registeredAtBlock,
        bool exists
    ) {
        CategoryInfo storage c = categories[categoryHash];
        return (c.labelHash, c.entryCount, c.registeredAtBlock, c.exists);
    }

    function getActiveEntryCount() external view returns (uint256 count) {
        uint256[] memory ids = _allEntryIds;
        for (uint256 i; i < ids.length;) {
            if (herbEntries[ids[i]].active) count++;
            unchecked { ++i; }
        }
    }

    function getContributorStats(address contributor) external view returns (
        uint256 totalEntries,
        uint256 vitality
    ) {
        totalEntries = _entryIdsByContributor[contributor].length;
        vitality = vitalityBalance[contributor];
    }

    function getLedgerDigest() external view returns (
        uint256 totalEntries,
        uint256 totalCategories,
        uint256 treasuryAccum,
        uint256 deployBlockNum,
        bool paused
    ) {
        return (
            entryCounter,
            categoryCounter,
            _treasuryAccum,
            deployBlock,
            ledgerPaused
        );
    }

    function getEntriesPaginated(uint256 offset, uint256 limit) external view returns (
        uint256[] memory ids,
        address[] memory contributors,
