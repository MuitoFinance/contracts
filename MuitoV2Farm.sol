// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../comm/MNTHelper.sol";
import "../comm/TransferHelper.sol";
import "../tokens/Token.sol";
import "../interface/IVault.sol";

/// @notice - This is the mainChef contract
contract MuitoV2Farm is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Bonus multiplier for farm.
    uint256 public constant BONUS_MULTIPLIER = 2;

    // User info
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    // Pool info
    struct PoolInfo {
        IERC20 assets;
        uint256 allocPoint;
        uint256 amount;
        uint256 withdrawFee;
        uint256 lastRewardTime;
        uint256 acctPerShare;
        IVault vault;
    }

    // Pool TVL
    struct PoolTvl {
        uint256 pid;
        IERC20 assets;
        uint256 tvl;
    }

    // Farm start timestamp
    uint256 public startTimestamp;

    // Farm bonus end timestamp
    uint256 public bonusEndTime;

    // Wrapped MNT token address
    address public wmnt;

    // Token address
    IERC20 public rewardToken;

    // Token amount per block created
    uint256 public tokenPerBlock;

    // Total allocation points
    uint256 public totalAllocPoint;

    // Total user revenue
    uint256 public totalUserRevenue;

    // Pool info
    PoolInfo[] public poolInfoList;

    // Each user stake token
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // User list
    address[] public userList;

    // MNT Transfer helper
    MNTHelper public wmntHelper;

    /// @notice Emitted when user deposit assets
    /// @param user The address that deposited
    /// @param pid The pool id that user deposited
    /// @param amount The amount of user deposited
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);

    /// @notice Emitted when user withdraw assets
    /// @param user The address that withdraw
    /// @param pid The pool id that user withdraw
    /// @param amount The amount of user withdraw
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    receive() external payable {}

    /// @notice Initialize the farm
    /// @param _rewardToken The reward token address
    /// @param _wmnt The wrapped MNT token address
    function initialize(
        IERC20 _rewardToken,
        address _wmnt
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        rewardToken = _rewardToken;
        wmnt = _wmnt;

        totalAllocPoint = 0;
        totalUserRevenue = 0;
        tokenPerBlock = 0;

        wmntHelper = new MNTHelper();
    }

    /// @notice Set the token per block
    /// @param _tokenPerBlock Token yield per block
    function setTokenPerBlock(uint256 _tokenPerBlock) public onlyOwner {
        tokenPerBlock = _tokenPerBlock;
    }

    /// @notice Set the farm start timestamp
    /// @param _startTimestamp The farm start timestamp(seconds)
    function setStartTimestamp(uint256 _startTimestamp) public onlyOwner {
        require(startTimestamp == 0, "Farm: already started");
        startTimestamp = _startTimestamp;
    }

    /// @notice Set bonus end time, bonus halved after end time.
    /// @param _bonusEndTime The bonus end timestamp(seconds)
    function setBonusEndTime(uint256 _bonusEndTime) public onlyOwner {
        require(startTimestamp > 0, "Farm: not start");
        require(_bonusEndTime > startTimestamp, "Farm: end time must greater than start time");

        bonusEndTime = _bonusEndTime;
    }

    /// @notice Set wrapped MNT token address
    function setWmnt(address _wmnt) public onlyOwner {
        require(_wmnt != address(0), "Farm: invalid WMNT address");
        wmnt = _wmnt;
    }

    /// @notice Set farm reward token
    function setRewardToken(IERC20 _token) public onlyOwner {
        require(address(_token) != address(0), "Farm: invalid token address");
        rewardToken = _token;
    }

    /// @notice Set total allocation points
    /// @param _totalAllocPoint The total allocation points
    function setTotalAllocPoint(uint256 _totalAllocPoint) public onlyOwner {
        totalAllocPoint = _totalAllocPoint;
    }

    /// @notice Get total user revenue
    function getTotalUserRevenue() public view returns (uint256) {
        return totalUserRevenue;
    }

    /// @notice Get user info
    /// @param _pid The pool id
    /// @param _user The user address
    /// @return No. of Users and user reward debt
    function getUserInfo(uint256 _pid, address _user) public view returns (uint256, uint256){
        UserInfo storage user = userInfo[_pid][_user];
        return (user.amount, user.rewardDebt);
    }

    /// @notice Get pool information
    /// @param _pid The pool id
    /// @return The pool information
    function getPoolInfo(uint256 _pid) public view returns (PoolInfo memory){
        return poolInfoList[_pid];
    }

    /// @notice Get the pool length
    function getPoolLength() public view returns (uint256){
        return poolInfoList.length;
    }

    /// @notice Get single pool TVL
    /// @param _pid The pool id
    function getPoolTvl(uint256 _pid) public view returns (uint256){
        PoolInfo storage pool = poolInfoList[_pid];
        return pool.vault.balance();
    }

    /// @notice Get total TVL
    function getPoolTotalTvl() public view returns (PoolTvl[] memory){
        uint256 _len = poolInfoList.length;
        PoolTvl[] memory _totalPoolTvl = new PoolTvl[](_len);

        for (uint256 pid = 0; pid < _len; pid++) {
            uint256 _tvl = getPoolTvl(pid);

            PoolTvl memory _pt = PoolTvl({
                pid: pid,
                assets: poolInfoList[pid].assets,
                tvl: _tvl
            });

            _totalPoolTvl[pid] = _pt;
        }
        return _totalPoolTvl;
    }

    /// @notice Start to farm
    /// @param _tokenPerBlock Token yield per block
    function startMining(uint256 _tokenPerBlock) public onlyOwner {
        require(startTimestamp == 0, "Farm: mining already started");
        require(_tokenPerBlock > 0, "Farm: token bonus per block must be over 0");

        startTimestamp = block.timestamp;

        tokenPerBlock = _tokenPerBlock;
        bonusEndTime = startTimestamp + 60 days;
    }

    /// @notice Add new pool
    /// @param _allocPoints The allocation points
    /// @param _token The pool asset
    /// @param _withUpdate The updated pool flag
    /// @param _withdrawFee The withdrawal fee
    /// @param _vault The vault address
    /// @param isNativeToken Pool asset native token identifier
    function addPool(
        uint256 _allocPoints,
        IERC20 _token,
        bool _withUpdate,
        uint256 _withdrawFee,
        address _vault,
        bool isNativeToken
    ) external onlyOwner {
        // Check if added
        checkDuplicatePool(_token);

        if (_withUpdate) {
            updateMassPools();
        }

        uint256 lastRewardTime = block.timestamp > startTimestamp ? block.timestamp : startTimestamp;

        // increase total alloc point
        totalAllocPoint = totalAllocPoint.add(_allocPoints);

        // approve token to vault
        if (isNativeToken == false) {
            IERC20(_token).safeIncreaseAllowance(address(_vault), type(uint256).max);
        }

        poolInfoList.push(PoolInfo({
            assets: _token,
            allocPoint: _allocPoints,
            amount: 0,
            withdrawFee: _withdrawFee,
            lastRewardTime: lastRewardTime,
            acctPerShare: 0,
            vault: IVault(_vault)
        }));
    }

    /// @notice Update the pool info
    /// @param _pid The pool id
    /// @param _allocPoints The allocation points
    /// @param _withUpdate The updated pool flag
    /// @param _withdrawFee The withdrawal fee
    /// @param _vault The vault address
    function setPool(
        uint256 _pid,
        uint256 _allocPoints,
        bool _withUpdate,
        uint256 _withdrawFee,
        IVault _vault
    ) external onlyOwner {

        if (_withUpdate) {
            updateMassPools();
        }

        // Recalculate the total alloc point
        totalAllocPoint = totalAllocPoint.sub(poolInfoList[_pid].allocPoint).add(_allocPoints);

        poolInfoList[_pid].allocPoint = _allocPoints;
        poolInfoList[_pid].withdrawFee = _withdrawFee;
        poolInfoList[_pid].vault = _vault;
    }

    /// @notice Set the pool asset
    /// @param _pid The pool id
    /// @param _token The pool asset
    function setPoolAsset(uint256 _pid, IERC20 _token) external onlyOwner {
        poolInfoList[_pid].assets = _token;

        // Re-approve token to vault
        _token.safeIncreaseAllowance(address(poolInfoList[_pid].vault), type(uint256).max);
    }

    /// @notice Update the pools
    function updateMassPools() public {
        for (uint256 i = 0; i < poolInfoList.length; i++) {
            updatePool(i);
        }
    }

    /// @notice Update the pool
    /// @param _pid The pool id
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfoList[_pid];

        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }

        if (block.timestamp > bonusEndTime) {
            tokenPerBlock = tokenPerBlock.div(BONUS_MULTIPLIER);
        }

        uint256 totalAmount = pool.amount;
        if (totalAmount <= 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }

        uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
        uint256 tokenReward = multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

        pool.acctPerShare = pool.acctPerShare.add(tokenReward.mul(1e18).div(totalAmount));
        pool.lastRewardTime = block.timestamp;
    }

    /// @notice Return the user pending rewards
    /// @param _pid The pool id
    /// @param _user The user address
    /// @return The pending rewards
    function pendingRewardToken(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfoList[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 acctPerShare = pool.acctPerShare;
        uint256 totalAmount = pool.amount;

        if (block.timestamp > pool.lastRewardTime && totalAmount > 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 tokenReward = multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            acctPerShare = acctPerShare.add(tokenReward.mul(1e18).div(totalAmount));
        }

        uint256 _rewards = user.amount.mul(acctPerShare).div(1e18).sub(user.rewardDebt);
        if (pool.withdrawFee == 0) {
            return _rewards;
        } else {
            uint256 _fee = _rewards.mul(pool.withdrawFee).div(1000);
            return _rewards.sub(_fee);
        }
    }

    /// @notice Calculate the rewards and transfer to user
    /// @param _pid The pool id
    /// @param _userAddr The user address
    function harvest(uint256 _pid, address _userAddr) public {
        require(_userAddr != address(0), "Farm: invalid user address");

        UserInfo storage user = userInfo[_pid][_userAddr];

        uint256 pendingRewards = pendingRewardToken(_pid, _userAddr);
        if (pendingRewards > 0) {
            user.rewardDebt = user.rewardDebt.add(pendingRewards);
            totalUserRevenue = totalUserRevenue.add(pendingRewards);
            safeTokenTransfer(_userAddr, pendingRewards);
        }
    }

    /// @notice Deposit assets to the farm
    /// @param _pid The pool id
    /// @param _amount The amount of assets to deposit
    function deposit(uint256 _pid, uint256 _amount) external payable nonReentrant {
        require(tokenPerBlock > 0, "Farm: not start yet");

        PoolInfo storage pool = poolInfoList[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        // process rewards
        if (user.amount > 0) {
            harvest(_pid, msg.sender);
        }

        // process WMNT
        if (address(pool.assets) == wmnt) {
            if (_amount > 0) {
                TransferHelper.safeTransferFrom(address(pool.assets), address(msg.sender), address(this), _amount);
                TransferHelper.safeTransfer(wmnt, address(wmntHelper), _amount);
                wmntHelper.withdrawMnt(wmnt, address(this), _amount);
            }

            if (msg.value > 0) {
                _amount = _amount.add(msg.value);
            }
        } else {
            if (_amount > 0) {
                TransferHelper.safeTransferFrom(address(pool.assets), address(msg.sender), address(this), _amount);
            }
        }

        if (_amount > 0) {
            pool.amount = pool.amount.add(_amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.acctPerShare).div(1e18);

        if (_amount > 0) {
            if (address(pool.assets) == wmnt) {
                pool.vault.deposit{value: _amount}(msg.sender, 0);
            } else {
                pool.vault.deposit(msg.sender, _amount);
            }
        }

        userList.push(msg.sender);

        emit Deposit(msg.sender, _pid, _amount);
    }

    /// @notice Withdraw assets from the farm
    /// @param _pid The pool id
    /// @param _amount The amount of assets to withdraw
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        require(tokenPerBlock > 0, "Farm: not start yet");

        PoolInfo storage pool = poolInfoList[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "Farm: withdraw amount exceeds balance");

        updatePool(_pid);

        // process rewards
        harvest(_pid, msg.sender);

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.amount = pool.amount.sub(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.acctPerShare).div(1e18);

        pool.vault.withdraw(msg.sender, _amount);

        emit Withdraw(msg.sender, _pid, _amount);
    }

    /// @dev Check the pool created or not
    function checkDuplicatePool(IERC20 _token) internal view {
        uint _existed = 0;
        for (uint256 i = 0; i < poolInfoList.length; i++) {
            if (poolInfoList[i].assets == _token) {
                _existed = 1;
                break;
            }
        }

        require(_existed == 0, "Farm: pool already existed");
    }

    /// @dev Transfer the rewards to user
    function safeTokenTransfer(address _user, uint256 _amount) internal {
        uint256 tokenBal = rewardToken.balanceOf(address(this));
        if (_amount > tokenBal) {
            rewardToken.safeTransfer(_user, tokenBal);
        } else {
            rewardToken.safeTransfer(_user, _amount);
        }
    }

    /// @dev Get the multiplier
    function getMultiplier(uint256 _from, uint256 _to) internal pure returns (uint256){
        return _to.sub(_from);
    }
}


