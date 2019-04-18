pragma solidity ^0.4.24;

import "./lib/SafeMath.sol";
import "./lib/DateTime.sol";
import "./lib/Utils.sol";

contract Game {
  using SafeMath for *;
  using DateTime for uint;

  uint constant offsetTimeZone = 8 hours;
  uint constant baseRate = 100;

  address public owner = 0xffffffffffffffffffffffffffffffffffffffff;
  uint public commEthBal; // community eth balance

  uint public vipPot; // vip奖池
  string public vipPotLastModified; // 最近修改vip奖池的时间 20181127

  uint public currRID; // 当前是第几局
  // TODO: change me back for production
  uint public rndTime = 1 hours;
  uint constant public LAND_NUM = 9;
  uint constant public currSeedPrice = 0.001 ether; // 当前种子价格
  uint constant public initKettlePrice = 0.01 ether;
  uint constant public initShovelPrice = 0.05 ether;

  uint highestRebate = 400 ether; // 最高返利
  mapping(uint => uint) mapLevel;
  mapping(uint => uint) mapRebate;

  struct Admin {
    bool isAdmin;
    uint rate; // need to divide by 100
  }
  mapping (address => Admin) public admins;

  uint adminCount;

  address[] public adminAddr = [
    0xffffffffffffffffffffffffffffffffffffffff // com
  ];

  //^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  // CONSTRUCTOR
  //^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  constructor() public { // 构造函数, 初始化参数
    // TODO: remove me for prod. lets start first round
    currRID = 1;
    // mapRIDToRnd[1].currPot = 1 ether;
    mapRIDToRnd[1].isBegin = true;
    mapRIDToRnd[1].isEnded = false;
    mapRIDToRnd[1].currShovelPrice = initShovelPrice;
    mapRIDToRnd[1].beginTime = block.timestamp;
    mapRIDToRnd[1].endTime = mapRIDToRnd[1].beginTime.add(rndTime);
    // TODO: init with proper value ?
    // vipPotLastModified =''; // 不需要初始化
    mapLevel[1] = 1 ether;
    mapLevel[2] = 5 ether;
    mapLevel[3] = 50 ether;
    mapLevel[4] = 100 ether;

    mapRebate[1] = 5; //5% 扩大了100倍
    mapRebate[2] = 10; //同上
    mapRebate[3] = 30; //同上
    mapRebate[4] = 50; //同上

    admins[adminAddr[0]] = Admin(true, 5);

    adminCount = 12;
  }

//****************
// ROUND DATA
//****************
  struct Round {
    uint RID;
    bool isBegin; // 游戏状态是否开始
    bool isEnded; // 游戏状态是否开始
    uint beginTime;
    uint endTime;
    uint currShovelPrice; // 当前铲子价格 本轮相关
    uint currHighestLID; // 当前最高树
    bool isHighestLandExisted; // 当前是否存在一个地块有最高树，lid为0的时候要和此标志位一起判断
    uint currPot; // 本轮奖池，来自于铲子
    uint nRndPot; // pot for next round, 种子+水壶
    uint ethNum;  // total eth in
    address lastWinner;
  }
  mapping (uint => Round) public mapRIDToRnd;

//****************
// TREE DATA
//****************
  struct Tree {
    uint landInx;
    address user; // 谁种的树
    uint kettlePrice; // kettle价格
    bool isDead; // true: 被铲, false: 活着/空地
    uint level; // 树等级, 1-种子, 2-4-树。地块才有0（空地）的情况，树没有，因为从种子开始才有树
    uint kettleNum; // 累计浇了多少壶水，一壶水涨一米
    uint kettleTime; // 累计浇了多少次水, 一次可以浇多壶
    uint kettleClock; // 浇水时间
    uint ethBalance;  // 树的总的balance
  }

  mapping (uint => mapping (uint => mapping (uint => Tree))) public mapRndTreeData; // RID => LID => TID => Tree

  mapping (uint => uint[LAND_NUM]) public mapRIDToTreeLevels;  // RID => 9块地tree level, 0-空地，1-种子，2-4-树
  mapping (uint => uint[LAND_NUM]) public mapRIDToTreeIDs;  // RID => 9块地tree ids, id从1开始

  // RID => PID => TIDs 用户最近投入eth的树, TIDs是一个uint[9], 树的num从1开始记录；值为0表示这个地块没有参与
  mapping (uint => mapping (address => uint[9])) public mapPlayerTree;

//****************
// PLAYER DATA
//****************
  struct Player { // 用户
    address user;
    uint ethBalance; // 提款数量
    uint vipBalance; // 返利
    uint expectedReward; // 预期收益
    uint lrnd;   // last round played
    uint level; // 1-4
    uint toBeVipTime; // 成为vip的时间
    mapping(address => Inviter) mapToInviter;
    address[] inviters;
  }

  struct Inviter { // 邀请者
    address master; // 被谁邀请的
    address user; // 自己的
    uint level; // 1-4
    uint toBeVipTime; // 成为vip的时间
  }

  struct dayRebate { // 每天的福利
    uint num; //邀请的数量
    uint rate; // 每天利率, 扩大了100倍
    uint amount; // 每天返利数量
  }

  mapping (address => mapping(string => dayRebate)) mapDateToRebate;
  // 0x7E825292c4014cF2654DACd6b5C9F8bD29482905 => 20181031 => dayRebate

  // 记录用户最近一次提币的数量
  mapping (address => uint) public mapPlayerToLastWithdraw;
  // RID => PID => LID => TID => eth 用户在树上投入的eth
  mapping (uint => mapping (address => mapping (uint => mapping (uint => uint)))) public mapPlayerEthByTree;
  // RID => PID => LID => TID => kettleNum 用户在树上浇了多少壶水
  mapping (uint => mapping (address => mapping (uint => mapping (uint => uint)))) public mapPlayerKettleNumByTree;
  // mapping(address => uint) mapAddrToEth; // eth列表 用户=>投入多少eth
  // mapping(address => uint) mapAddrToKettleNum; // 浇水列表 用户=>投入多少壶水

  mapping (address => Player) public mapAddrToPlayer;

//****************
// EVENTS
//****************
  event onPay( // 购买事件
    string name, // 购买事件的名称
    address indexed from, // 购买者
    uint num, // 数量
    uint value, // 花费的钱
    uint treeID
  );

  event onPotChanged(  // 奖池变化
    uint num
  );

  event onWithdraw
  (
    address addr,
    uint256 ethOut
  );

  event onRndStarted
  (
    uint rndNum,
    uint256 endTime
  );

  event onVip( // vip事件
    address indexed inviter, // 邀请者
    address indexed user, // 用户
    uint level, //等级
    string extra
  );

//****************
// MODIFIER
//****************
  modifier isHuman() {
    address _addr = msg.sender;
    uint256 _codeLength;

    assembly {_codeLength := extcodesize(_addr)}
    require(_codeLength == 0, "sorry humans only");
    _;
  }

  modifier isAdmin() { // 权限验证
    require(msg.sender == owner || admins[msg.sender].isAdmin, "only owner can do that");
    _;
  }

  modifier isGameBegin() { // 游戏是否开始
    require(mapRIDToRnd[currRID].isBegin == true, "the game not beginning");
    _;
  }

  modifier isGameEnded() { // 游戏是否开始
    require(mapRIDToRnd[currRID].isEnded == true, "the game not beginning");
    _;
  }

  function addMoney() public payable isHuman {
    require(msg.value > 0, "value must be bigger than 0");
    mapRIDToRnd[currRID].currPot = mapRIDToRnd[currRID].currPot.add(msg.value);
    emit onPotChanged(msg.value);
  }

  function endRound() private {
    // set end flag
    mapRIDToRnd[currRID].isEnded = true;

    // start next round
    currRID = currRID.add(1);

    // 初始化next round data
    initRndData(currRID);

    // event
    emit onRndStarted(currRID, mapRIDToRnd[currRID].endTime);
  }

  function initRndData(uint rid) private returns (uint) {
    require(rid > 0, "round must be bigger than 1");
    if (mapRIDToRnd[rid - 1].nRndPot > 0) {
      // mapRIDToRnd[rid].currPot = mapRIDToRnd[rid].currPot.add(mapRIDToRnd[rid - 1].nRndPot);
      mapRIDToRnd[rid].currPot = mapRIDToRnd[rid - 1].nRndPot;
    }
    mapRIDToRnd[rid].isBegin = true;
    mapRIDToRnd[rid].isEnded = false;
    mapRIDToRnd[rid].currShovelPrice = initShovelPrice;
    mapRIDToRnd[rid].beginTime = block.timestamp;
    mapRIDToRnd[rid].endTime = mapRIDToRnd[rid].beginTime.add(rndTime);
  }

  function buySeed(uint landInx) public payable isGameBegin isHuman { // 购买种子 并种地
    if (block.timestamp > mapRIDToRnd[currRID].endTime && mapRIDToRnd[currRID].isEnded == false) {
      endRound();
      updatePlayerVault();
    }

    require(msg.value == currSeedPrice, "pay value must equal currSeedPrice");
    require(mapRIDToTreeLevels[currRID][landInx] == 0, " the land must blank"); // 此地必须空

    uint _toComm = currSeedPrice / 10;  // 分给社区的eth
    uint _toTree = currSeedPrice.sub(_toComm); // 分给tree和下一轮奖池的eth

    uint _newTID = mapRIDToTreeIDs[currRID][landInx].add(1); // 树的id++
    //****************
    // update tree info
    //****************
    // 更新全局状态: tree level, tree ids
    mapRIDToTreeLevels[currRID][landInx] = 1;
    mapRIDToTreeIDs[currRID][landInx] = _newTID;
    // 种一棵新树
    mapRndTreeData[currRID][landInx][_newTID] = Tree(landInx, msg.sender, initKettlePrice, false, 1, 0, 0, 0, _toTree);

    //****************
    // update round info
    //****************
    // 更新本轮总eth: ethNum
    mapRIDToRnd[currRID].ethNum = mapRIDToRnd[currRID].ethNum.add(currSeedPrice);
    // 玩家每笔交易的10%自动抽取
    commEthBal = commEthBal.add(_toComm);

    // 更新下一轮奖金池 nRndPot，本轮奖金池 currPot不更新
    mapRIDToRnd[currRID].nRndPot = mapRIDToRnd[currRID].nRndPot.add(_toTree);

    // update lastWinner
    if (mapRIDToRnd[currRID].lastWinner != msg.sender) {
      mapRIDToRnd[currRID].lastWinner = msg.sender;
    }

    //****************
    // update player info
    //****************
    // mapPlayerEthByTree; // RID => PID => LID => TID => eth 用户在树上投入的eth
    // mapPlayerKettleNumByTree; // RID => PID => LID => TID => kettleNum 用户在树上浇了多少壶水
    mapPlayerEthByTree[currRID][msg.sender][landInx][_newTID] = _toTree;

    // 更新用户所有的eth收入到ethBalance
    updatePlayerVault();
    // 更新用户最近投入eth的树，要放在updatePlayerVault之后
    mapPlayerTree[currRID][msg.sender][landInx] = _newTID;

    //****************
    // event
    //****************
    emit onPay("buySeed", msg.sender, 1, msg.value, landInx);
    addRebate(msg.value, msg.sender); // 计算vip折扣, 并从vipPot减去数值
  }

  function getTreeLevelByKettleNum(uint kettleNum) private pure returns (uint) {
    if (kettleNum < 10) return 2;
    if (kettleNum >= 10 && kettleNum < 50) return 3;
    if (kettleNum >= 50) return 4;
  }

  // 浇水
  function buyKettle(uint landInx) public payable isGameBegin { // isHuman Stack too deep
    if (block.timestamp > mapRIDToRnd[currRID].endTime && mapRIDToRnd[currRID].isEnded == false) {
      endRound();
      updatePlayerVault();
      return;
    }

    // require(msg.value > currKettlePrice, "pay value must equal currKettlePrice");
    uint _currTID = mapRIDToTreeIDs[currRID][landInx];
    Tree storage _currTree = mapRndTreeData[currRID][landInx][_currTID];

    require(_currTree.level > 0, "land is blank"); //有种子么
    require(msg.value >= _currTree.kettlePrice, "paid eth must be larger than kettle price");

    // 只允许购买整壶水，剩下的钱存入用户的合约ethBalance中
    // 计算可以购买几壶水
    uint _kettleNum = msg.value / _currTree.kettlePrice;
    uint buyKettleLeft = msg.value % _currTree.kettlePrice;

    uint _ethUsed = msg.value.sub(buyKettleLeft);
    uint _toComm = _ethUsed / 10;  // 分给社区的eth
    uint _toTree = _ethUsed.sub(_toComm); // 分给tree和下一轮奖池的eth
    uint _playerEthByTree = mapPlayerEthByTree[currRID][msg.sender][landInx][_currTID];
    uint _playerKettleNumByTree = mapPlayerKettleNumByTree[currRID][msg.sender][landInx][_currTID];

    //****************
    // update round info
    //****************
    // 更新本轮总eth: ethNum
    mapRIDToRnd[currRID].ethNum = mapRIDToRnd[currRID].ethNum.add(_ethUsed);
    // 玩家每笔交易的10%自动抽取
    commEthBal = commEthBal.add(_toComm);

    // 更新下一轮奖金池 nRndPot，本轮奖金池 currPot不更新
    mapRIDToRnd[currRID].nRndPot = mapRIDToRnd[currRID].nRndPot.add(_toTree);

    // update lastWinner
    if (mapRIDToRnd[currRID].lastWinner != msg.sender) {
      mapRIDToRnd[currRID].lastWinner = msg.sender;
    }

    //****************
    // update tree info
    //****************
    // eth记录到树中
    _currTree.ethBalance = _currTree.ethBalance.add(_toTree);
    // 增加树的浇水数量（米） kettleNum
    _currTree.kettleNum = _currTree.kettleNum.add(_kettleNum);
    // 增加树的浇水次数
    _currTree.kettleTime = _currTree.kettleTime.add(1);
    // 更新树的浇水时间
    _currTree.kettleClock = block.timestamp;
    // 增加这个树的水壶价格
    _currTree.kettlePrice = _currTree.kettlePrice.add(0.01 ether);

    // 更新本树的级别 level
    _currTree.level = getTreeLevelByKettleNum(_currTree.kettleNum);
    // 更新全局状态: tree level, tree ids
    mapRIDToTreeLevels[currRID][landInx] = _currTree.level;

    // 更新最高树所在的land id
    uint _highestLID = mapRIDToRnd[currRID].currHighestLID;
    uint _highestTID = mapRIDToTreeIDs[currRID][_highestLID];
    if (_currTree.kettleNum > mapRndTreeData[currRID][_highestLID][_highestTID].kettleNum) {
      mapRIDToRnd[currRID].currHighestLID = landInx;
      mapRIDToRnd[currRID].isHighestLandExisted = true;
    } else if (landInx != _highestLID && _currTree.kettleNum == mapRndTreeData[currRID][_highestLID][_highestTID].kettleNum) {
      mapRIDToRnd[currRID].currHighestLID = 0;
      mapRIDToRnd[currRID].isHighestLandExisted = false;
    }
    //****************
    // update player info
    //****************
    mapPlayerEthByTree[currRID][msg.sender][landInx][_currTID] = _playerEthByTree.add(_toTree);
    mapPlayerKettleNumByTree[currRID][msg.sender][landInx][_currTID] = _playerKettleNumByTree.add(_kettleNum);

    // 存储余额
    if (buyKettleLeft > 0) {
      mapAddrToPlayer[msg.sender].ethBalance = mapAddrToPlayer[msg.sender].ethBalance.add(buyKettleLeft);
    }

    // 更新用户所有的eth收入到ethBalance
    updatePlayerVault();
    // 更新用户最近投入eth的树，要放在updatePlayerVault之后
    mapPlayerTree[currRID][msg.sender][landInx] = _currTID;

    //****************
    // event
    //****************
    emit onPay("buyKettle", msg.sender, _kettleNum, msg.value, landInx);
    addRebate(msg.value, msg.sender); // 计算vip折扣, 并从vipPot减去数值
  }

  function buyShovel(uint landInx) public payable isGameBegin isHuman {
    if (block.timestamp > mapRIDToRnd[currRID].endTime && mapRIDToRnd[currRID].isEnded == false) {
      endRound();
      updatePlayerVault();
      return;
    }

    uint _currTID = mapRIDToTreeIDs[currRID][landInx];
    Tree storage _currTree = mapRndTreeData[currRID][landInx][_currTID];
    uint currShovelPrice = mapRIDToRnd[currRID].currShovelPrice;

    require(_currTree.level > 0, "tree level must be bigger than 0");
    // 用户付出的钱必须是当前铲子价格
    require(msg.value == currShovelPrice, "the eth you pay is incorrect");

    uint _ethUsed = currShovelPrice;
    uint _toComm = _ethUsed / 10;  // 分给社区的eth
    uint _toCurrPot = _ethUsed.sub(_toComm); // 分给tree和下一轮奖池的eth

//****************
// update round info
//****************
    // 更新本轮总eth: ethNum
    mapRIDToRnd[currRID].ethNum = mapRIDToRnd[currRID].ethNum.add(_ethUsed);
    // 玩家每笔交易的10%自动抽取
    commEthBal = commEthBal.add(_toComm);

    // 更改本轮奖金池: currPot + _toCurrPot
    mapRIDToRnd[currRID].currPot = mapRIDToRnd[currRID].currPot.add(_toCurrPot);
    // 更新下一轮奖金池 nRndPot
    mapRIDToRnd[currRID].nRndPot = mapRIDToRnd[currRID].nRndPot.sub(_currTree.ethBalance);

    // update lastWinner
    if (mapRIDToRnd[currRID].lastWinner != msg.sender) {
      mapRIDToRnd[currRID].lastWinner = msg.sender;
    }

    // 增加铲子价格, 铲子每被任何玩家买一次, 价格都增加0.1eth
    mapRIDToRnd[currRID].currShovelPrice = currShovelPrice.add(0.1 ether);

//****************
// update tree info
//****************
    // 更新树 isDead = true, 其它数据保留
    _currTree.isDead = true;

    // 更新全局状态: tree level, tree ids
    mapRIDToTreeLevels[currRID][landInx] = 0;

    // 更新当前最高树所在的land id currHighestLID
    if (!mapRIDToRnd[currRID].isHighestLandExisted || landInx == mapRIDToRnd[currRID].currHighestLID) {
      uint _highestTreeKettleNum = 0;
      for (uint i = 0; i < LAND_NUM; i++) {
        if (mapRIDToTreeLevels[currRID][i] < 2 || (i == landInx)) continue; // tree must alive
        if (mapRndTreeData[currRID][i][mapRIDToTreeIDs[currRID][i]].kettleNum > _highestTreeKettleNum) {
          mapRIDToRnd[currRID].currHighestLID = i;
          mapRIDToRnd[currRID].isHighestLandExisted = true;
          _highestTreeKettleNum = mapRndTreeData[currRID][i][mapRIDToTreeIDs[currRID][i]].kettleNum;
        } else if (mapRndTreeData[currRID][i][mapRIDToTreeIDs[currRID][i]].kettleNum == _highestTreeKettleNum) {
          mapRIDToRnd[currRID].currHighestLID = 0;
          mapRIDToRnd[currRID].isHighestLandExisted = false;
        }
      }
    }

//****************
// update player info
//****************
    // 更新用户所有的eth收入到ethBalance
    updatePlayerVault();

//****************
// event
//****************
    emit onPay("buyShovel", msg.sender, 1, msg.value, landInx);

    // event: 本轮奖金池
    emit onPotChanged(mapRIDToRnd[currRID].currPot);
    addRebate(msg.value, msg.sender);  //计算vip折扣, 并从vipPot减去数值
  }

  function withdraw() public isHuman returns (uint) {  // 用户提币
    if (block.timestamp > mapRIDToRnd[currRID].endTime && mapRIDToRnd[currRID].isEnded == false) {
      endRound();
    }
    // 更新用户所有的eth收入到ethBalance
    updatePlayerVault();

    address _addr = msg.sender;
    uint _earnings = mapAddrToPlayer[_addr].ethBalance.add(mapAddrToPlayer[_addr].vipBalance);

    require(_earnings > 0, "提款数大于0");
    require(_earnings < address(this).balance, "提款数不能大于合约余额");
    vipSettlement(); // vip奖池结算

    // 先清零
    mapAddrToPlayer[_addr].ethBalance = 0;
    mapAddrToPlayer[_addr].vipBalance = 0;
    // 再转账
    _addr.transfer(_earnings);

    emit onWithdraw(_addr, _earnings);
    return _earnings;
  }

  /**
    * @dev vault earnings 不包含vip的返还
    * @return earnings in wei format
    */
  function getPlayerEthEarning(address _addr) public view returns (uint) {
    uint _lrnd = mapAddrToPlayer[_addr].lrnd;
    // 初始化为玩家ethBalance
    uint _ethBalance = mapAddrToPlayer[_addr].ethBalance;
    uint _rndEarning = getPlayerRewardByRnd(_addr, _lrnd);
    // 1. 加入玩家上一轮收益
    // 2. 加入玩家本轮收益：参与的本轮已结束，且没有人触发结束，则把当前轮收益加入进来（用户如果提币，则会触发endRound）
    if (currRID > 1 && (currRID > _lrnd || (block.timestamp > mapRIDToRnd[_lrnd].endTime && mapRIDToRnd[_lrnd].isEnded == false))) {
      _ethBalance = _ethBalance.add(_rndEarning);
    }
    // 被铲的树的eth
    // 3. 上一局被铲的树的eth
    if (currRID > _lrnd) {
      _ethBalance = _ethBalance.add(getEthFromDeadTree(_addr, _lrnd));
    }
    // 4. 本局被铲的树的eth
    _ethBalance = _ethBalance.add(getEthFromDeadTree(_addr, currRID));

    return _ethBalance;
  }

  // 获取用户在被铲的树上投入的eth总和
  function getEthFromDeadTree(address _addr, uint _rid) public view returns (uint) {
    uint _tid;
    uint _ethBalance;
    for (uint _lid = 0; _lid < LAND_NUM; _lid++) {
      _tid = mapPlayerTree[_rid][_addr][_lid];
      if (_tid > 0 && mapRndTreeData[_rid][_lid][_tid].isDead) { // 这个地块有参与的树: id > 1
        _ethBalance = _ethBalance.add(mapPlayerEthByTree[_rid][_addr][_lid][_tid]);
      }
    }

    return _ethBalance;
  }

  // 可以随时提取的eth数量，只显示，不更新，包含ethBalance和vipBalance
  function getPlayerEarnings(address _addr) public view returns (uint, uint, uint, bool) {
    uint total = commEthBal;
    if (!equalStr(getDateForZone(block.timestamp), vipPotLastModified)) {
      total = total.add(vipPot);
    }

    return (
      getPlayerEthEarning(_addr),
      mapAddrToPlayer[_addr].vipBalance,
      total.mul(admins[_addr].rate) / 100,
      admins[_addr].isAdmin
    );
  }

  function updatePlayerVault() private {
    // mapPlayerTree: RID => PID => TIDs
    address _addr = msg.sender;
    uint _prevRID = mapAddrToPlayer[_addr].lrnd;
    uint _ethBalance = getPlayerEthEarning(_addr);

    if (mapRIDToRnd[currRID].isEnded) {
      _ethBalance = _ethBalance.add(getPlayerRewardByRnd(_addr, currRID));
    }
    // 返还玩家所有收益
    mapAddrToPlayer[_addr].ethBalance = _ethBalance;

    for (uint i = 0; i < LAND_NUM; i++) {
      if (currRID > _prevRID && mapPlayerTree[_prevRID][_addr][i] > 0) { // 这个地块有被铲掉的树 : id > 1
        // 将树id设为0，表示此地块没有被铲的树，防止未来重复返还eth
        mapPlayerTree[_prevRID][_addr][i] = 0;
      }

      if (mapPlayerTree[currRID][_addr][i] > 0) { // 这个地块有被铲掉的树: id > 1
        // 将树id设为0，表示此地块没有被铲的树，防止未来重复返还eth
        mapPlayerTree[currRID][_addr][i] = 0;
      }
    }
    // 修改lrnd为currRID，下次就不会在重复返还上一局的eth了
    mapAddrToPlayer[_addr].lrnd = currRID;
  }

  function getPlayerExpectedReward(address _addr) public view returns (uint) {
    return getPlayerRewardByRnd(_addr, currRID);
  }

  function getPlayerRewardByRnd(address _addr, uint rid) public view returns (uint) {
    if (rid < 1) return 0;
    uint currPot = mapRIDToRnd[rid].currPot;
    uint lastWinnerReward = (_addr == mapRIDToRnd[rid].lastWinner) ? (currPot / 10) : 0;
    uint highestTreeReward = getPlayerHighestTreeReward(_addr, rid);
    return (lastWinnerReward.add(highestTreeReward));
  }

  function getPlayerHighestTreeReward(address _addr, uint rid) public view returns (uint) {
  // function getPlayerHighestTreeReward(address _addr, uint rid) private view returns (uint) {
    if (!mapRIDToRnd[rid].isHighestLandExisted) return 0;
    uint _pot = mapRIDToRnd[rid].currPot;
    uint _highestLID = mapRIDToRnd[rid].currHighestLID;
    uint _highestTID = mapRIDToTreeIDs[rid][_highestLID];
    Tree storage _highestTree = mapRndTreeData[rid][_highestLID][_highestTID];
    if (_pot == 0 || mapRIDToTreeLevels[rid][_highestLID] < 2) return 0;
    // 10%留给最后操作奖, 剩下的给最高树
    uint _highestTreeReward = _pot.sub(_pot / 10);

    // mapPlayerKettleNumByTree; // RID => PID => LID => TID => kettleNum 用户在树上浇了多少壶水
    uint _playerKettleNum = mapPlayerKettleNumByTree[rid][_addr][_highestLID][_highestTID];
    // 一个种子算一米
    if (_highestTree.user == _addr) {
      return _highestTreeReward.mul(_playerKettleNum.add(1)) / _highestTree.kettleNum.add(1);
    } else {
      return _highestTreeReward.mul(_playerKettleNum) / _highestTree.kettleNum.add(1);
    }
  }

  function getCurrRoundInfo()
    public
    view
    returns (uint, uint, uint, uint, uint[9], uint[], uint[], uint[], bool)
  {
    (uint[] memory _kettleNum, uint[] memory _kettleTime, uint[] memory _kettlePrice) = getAllTreeKettleInfo();

    return (
      currRID,
      mapRIDToRnd[currRID].currPot,
      mapRIDToRnd[currRID].endTime,
      mapRIDToRnd[currRID].currShovelPrice,
      mapRIDToTreeLevels[currRID],
      _kettleNum,
      _kettleTime,
      _kettlePrice,
      mapRIDToRnd[currRID].isEnded
    );
  }

  function getAllTreeKettleInfo() private view returns (uint[], uint[], uint[]) {
    uint[] memory _kettleNum = new uint[](9);
    uint[] memory _kettleTime = new uint[](9);
    uint[] memory _kettlePrice = new uint[](9);
    uint _currTID;

    for (uint i = 0; i < LAND_NUM; i++) {
      _currTID = mapRIDToTreeIDs[currRID][i];
      // _currTree = mapRndTreeData[currRID][i][_currTID];
      _kettleNum[i] = mapRndTreeData[currRID][i][_currTID].kettleNum;
      _kettleTime[i] = mapRndTreeData[currRID][i][_currTID].kettleTime;
      _kettlePrice[i] = mapRndTreeData[currRID][i][_currTID].kettlePrice;
    }
    return (
      _kettleNum,
      _kettleTime,
      _kettlePrice
    );
  }

  function changeRndTime(uint time) public isAdmin isHuman {
    rndTime = time.mul(1 minutes);
  }

  /** upon contract deploy, it will be deactivated.  this is a one time
    * use function that will activate the contract.  we do this so devs
    * have time to set things up on the web end
  **/

  bool public activated = false;

  function startGame() public isAdmin isHuman {
    // can only be ran once
    require(activated == false, "bigtree already activated");

    // activate the contract
    activated = true;
    vipPotLastModified = getDateForZone(block.timestamp);
    // lets start first round
    // currRID = 1;
    // initRndData(currRID);
    // mapRIDToRnd[1].currPot = 1;
  }

  function stopGame() public isAdmin isHuman {
    activated = false;
  }

  function close() public isAdmin {
    selfdestruct(owner);
  }

  function getDateForZone(uint _now) private returns(string) {
    uint _time = _now.add(offsetTimeZone);

    DateTime._DateTime memory _dt = _time.parseTimestamp();

    string memory _month = Utils.uint2str(_dt.month);
    string memory _day = Utils.uint2str(_dt.day);

    if(_dt.month < 10) {
      _month = Utils.strConcat(Utils.uint2str(0), Utils.uint2str(_time.getMonth()));
    }

    if(_dt.day < 10) {
      _day = Utils.strConcat("0", Utils.uint2str(_time.getDay()));
    }

    return Utils.strConcat(Utils.uint2str(_dt.year), _month, _day);
  }

  function getVip(address _who) public view isHuman returns (uint){
    return mapAddrToPlayer[_who].level;
  }

  function getInvitationNum(address _who) public view isHuman returns (uint){
    return mapDateToRebate[_who][getDateForZone(block.timestamp)].num;
  }

  function buyVip(uint level) public payable isHuman isGameBegin {
    require(level > 0, "level大于等于1");
    require(level < 5, "level小于等于4");
    require(level > mapAddrToPlayer[msg.sender].level, "vip等级不能降低或重复购买");

    require(mapLevel[level] > 0, "_value大于0");
    require(msg.value == mapLevel[level], "");

    mapAddrToPlayer[msg.sender].user = msg.sender;
    mapAddrToPlayer[msg.sender].level = level;
    mapAddrToPlayer[msg.sender].toBeVipTime = block.timestamp;

    mapAddrToPlayer[msg.sender].toBeVipTime = block.timestamp;

    // 如果升级, 清空原来邀请的用户
    mapDateToRebate[msg.sender][getDateForZone(block.timestamp)].rate = 0;
    mapDateToRebate[msg.sender][getDateForZone(block.timestamp)].num = 0;

    vipSettlement(); // 结算vip奖池
    addVipPot(msg.value); // vip奖池入账

    emit onVip(0, msg.sender, level, "vip");
  }

  function invitation(address _inviter, uint level) public payable isHuman isGameBegin {
    // 通过https://treegame.vip/?addr=0x7E825292c4014cF2654DACd6b5C9F8bD29482905&level=2
    // 可以自己邀请自己
    // 可以重复购买

    require(level>0, "level大于等于1");
    require(level<5, "level小于等于4");
    require(mapAddrToPlayer[_inviter].level == level, "被邀请者等级必须等于邀请者");

    uint _value = mapLevel[level];
    require(_value>0, "_value大于0");
    require(msg.value == _value, "");

    mapAddrToPlayer[msg.sender].toBeVipTime = block.timestamp;
    mapAddrToPlayer[msg.sender].level = level;

    mapAddrToPlayer[_inviter].inviters.push(msg.sender);
    mapAddrToPlayer[_inviter].mapToInviter[msg.sender] = Inviter(_inviter, msg.sender,level, block.timestamp);

    uint _num = mapDateToRebate[_inviter][getDateForZone(block.timestamp)].num.add(1);
    uint _rate = (mapRebate[level]).mul(_num);

    if (_rate > baseRate.mul(2)) { // _rate最大是200%, 此处扩大了100倍
      _rate = baseRate.mul(2);
    }

    mapDateToRebate[_inviter][getDateForZone(block.timestamp)].num = _num;
    mapDateToRebate[_inviter][getDateForZone(block.timestamp)].rate = _rate;

    vipSettlement(); // 结算vip奖池
    addVipPot(msg.value); // vip奖池入账

    emit onVip(_inviter, msg.sender, level, "invitation");
  }

  function addRebate(uint _val, address _who) private {  //计算vip折扣, 并从vipPot减去数值

    uint rate = mapDateToRebate[_who][getDateForZone(block.timestamp)].rate;

    uint _rebate = _val.mul(rate)/baseRate; //之前rate扩大100倍, 此处缩小100倍

    // 如果达到highestRebate, 优惠额度不在增加
    uint _amount = mapDateToRebate[_who][getDateForZone(block.timestamp)].amount;
    uint gap = highestRebate.sub(_amount); // gap会等于0

    if(gap >= _rebate){ // 不能超过最大折扣数量
      subVipPot(_rebate);
      mapDateToRebate[_who][getDateForZone(block.timestamp)].amount = _amount.add(_rebate);
      mapAddrToPlayer[_who].vipBalance = mapAddrToPlayer[_who].vipBalance.add(_rebate);
    }else { //如果超过了, 补齐差值, 凑足400ether
      subVipPot(gap);
      mapDateToRebate[_who][getDateForZone(block.timestamp)].amount = highestRebate;
      mapAddrToPlayer[_who].vipBalance = mapAddrToPlayer[_who].vipBalance.add(gap);
    }


  }

  function withdrawComm() public isHuman returns (uint) {  // admin提币
    address _addr = msg.sender;
    address _tmpAddr;
    uint _tmpBal;
    uint _tmpBalTotal;
    uint _eth;
    require(admins[_addr].isAdmin, "You need to be one of the community members.");
    vipSettlement(); // vip奖池结算

    if (commEthBal > 0) {
      for (uint i = 0; i < adminCount - 1; i++) {
        _tmpAddr = adminAddr[i];
        _tmpBal = commEthBal.mul(admins[_tmpAddr].rate) / 100;
        _tmpBalTotal = _tmpBalTotal.add(_tmpBal);
        mapAddrToPlayer[_tmpAddr].ethBalance = mapAddrToPlayer[_tmpAddr].ethBalance.add(_tmpBal);
      }
      // 最后一个单独处理
      mapAddrToPlayer[adminAddr[adminCount - 1]].ethBalance = mapAddrToPlayer[adminAddr[adminCount - 1]].ethBalance.add(commEthBal.sub(_tmpBalTotal));
      // 清零
      commEthBal = 0;
    }
    _eth = mapAddrToPlayer[_addr].ethBalance.add(mapAddrToPlayer[_addr].vipBalance);
    // 记录提币记录
    mapPlayerToLastWithdraw[_addr] = _eth;
    // 先清零
    mapAddrToPlayer[_addr].ethBalance = 0;
    mapAddrToPlayer[_addr].vipBalance = 0;

    require(_eth > 0, "You need to have eth.");

    // 再转账
    _addr.transfer(_eth);

    emit onWithdraw(_addr, _eth);
    return _eth;
  }

  // vip奖池的结算
  // buyvip invitation的时候 触发vip结算
  function vipSettlement() private {
    // 比较时间字符串

    if (!equalStr(getDateForZone(block.timestamp), vipPotLastModified)){ // 如果不一致, 需要结算, vipPot的剩余资金进入commEthBal
      commEthBal.add(vipPot);
      vipPot = 0; // 清零
      vipPotLastModified = getDateForZone(block.timestamp);
    }
  }

  // vip奖池进账
  function addVipPot(uint _val) private {
    vipPot = vipPot.add(_val);
  }

  // vip奖池出账
  function subVipPot(uint _val) private {
    vipPot = vipPot.sub(_val);
  }

  function equalStr(string a, string b) private returns (bool) {
    return keccak256(a) == keccak256(b);
  }

}