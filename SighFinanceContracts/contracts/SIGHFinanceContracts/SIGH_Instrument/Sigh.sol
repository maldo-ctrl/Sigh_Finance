pragma solidity ^0.5.16;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol"; 
import "openzeppelin-solidity/contracts/token/ERC20/ERC20Detailed.sol"; 

import "openzeppelin-solidity/contracts/utils/Address.sol"; 
import "openzeppelin-solidity/contracts/math/SafeMath.sol"; 

contract SIGH is ERC20, ERC20Detailed('SIGH Instrument : A free distributor of future expected accumulated value of financial assets','SIGH',uint8(18) ) {

    using SafeMath for uint256;    // Time based calculations
    using Address for address;

    address private _owner;
    address private treasury; 
    address private SpeedController;

    uint256 private constant INITIAL_SUPPLY = 5 * 10**6 * 10**18; // 5 Million (with 18 decimals)
    uint256 private prize_amount = 500 * 10**18;

    uint256 private totalAmountBurnt;

    struct mintSnapshot {
        uint cycle;
        uint era;
        uint inflationRate;
        uint mintedAmount;
        uint mintSpeed;
        uint newTotalSupply;
        address minter;
        uint blockNumber;
    }

    mintSnapshot[] private mintSnapshots;

    uint256 public constant CYCLE_BLOCKS = 4;  // 24*60*60 (i.e seconds in 1 day )
    uint256 public constant FINAL_CYCLE = 77; // 10 years (3650 days) + 60 days

    uint256 private Current_Cycle; 
    uint256 private Current_Era;
    uint256 private currentDivisibilityFactor = 100;

    bool private mintingActivated = false;
    uint256 private previousMintBlock;

    struct Era {
        uint256 startCycle;
        uint256 endCycle;
        uint256 divisibilityFactor;
    }

    Era[11] private _eras;

    event NewEra(uint newEra, uint blockNumber, uint timeStamp );

    event MintingInitialized(address speedController, address treasury, uint256 blockNumber);
    event SIGHMinted( address minter, uint256 cycle, uint256 Era, uint inflationRate, uint256 amountMinted, uint mintSpeed, uint256 current_supply, uint256 block_number);
    event SIGHBurned( uint256 burntAmount, uint256 totalBurnedAmount, uint256 currentSupply, uint blockNumber);

    // constructing  
    constructor () public {
        _owner = _msgSender();
        _mint(_owner,INITIAL_SUPPLY);
        mintSnapshot  memory currentMintSnapshot = mintSnapshot({ cycle:Current_Cycle, era:Current_Era, inflationRate: uint(0), mintedAmount:INITIAL_SUPPLY, mintSpeed:uint(0), newTotalSupply:totalSupply(), minter: msg.sender, blockNumber: block.number });
        mintSnapshots.push(currentMintSnapshot);                                                    // MINT SNAPSHOT ADDED TO THE ARRAY
    }

    // ################################################
    // #######   FUNCTIONS TO INITIATE MINTING  #######
    // ################################################

    function initMinting(address newSpeedController, address _treasury) public returns (bool) {
        require(_msgSender() == _owner,"Mining can only be initialized by the owner." );
        require(newSpeedController != address(0), "Not a valid Speed Controller address");
        require(_treasury != address(0), "Not a valid Treasury address");
        // require(!mintingActivated, "Minting can only be initialized once" );

        SpeedController = newSpeedController;
        treasury = _treasury;
        _initEras();
        
        emit MintingInitialized(SpeedController, treasury, block.number );
        mintingActivated = true;
    }

    function _initEras() private {
        _eras[0] = Era(1, 6, 100 );        // 96 days
        _eras[1] = Era(7, 13, 200 );       // 1 year
        _eras[2] = Era(14, 20, 400 );      // 1 year
        _eras[3] = Era(21, 27, 800 );       // 1 year
        _eras[4] = Era(28, 34, 1600 );     // 1 year
        _eras[5] = Era(35, 41, 3200 );      // 1 year   
        _eras[6] = Era(42, 48, 6400 );       // 1 year
        _eras[7] = Era(49, 55, 12800 );        // 1 year
        _eras[8] = Era(56, 62, 25600 );        // 1 year
        _eras[9] = Era(63, 69, 51200 );        // 1 year
        _eras[10] = Era(70, 77, 102400 );       // 1 year
    }

    // function _initEras() private {
    //     _eras[0] = Era(1, 96, 100 );        // 96 days
    //     _eras[1] = Era(97, 462, 200 );       // 1 year
    //     _eras[2] = Era(463, 828, 400 );      // 1 year
    //     _eras[3] = Era(829, 1194, 800 );       // 1 year
    //     _eras[4] = Era(1195, 1560, 1600 );     // 1 year
    //     _eras[5] = Era(1561, 1926, 3200 );      // 1 year   
    //     _eras[6] = Era(1927, 2292, 6400 );       // 1 year
    //     _eras[7] = Era(2293, 2658, 12800 );        // 1 year
    //     _eras[8] = Era(2659, 3024, 25600 );        // 1 year
    //     _eras[9] = Era(3025, 3390, 51200 );        // 1 year
    //     _eras[10] = Era(3391, 3756, 102400 );       // 1 year
    // }



    // ############################################################
    // ############   OVER-LOADING TRANSFER FUNCTON    ############
    // ############################################################

    function _transfer(address sender, address recipient, uint256 amount) internal {
        if (isMintingPossible()) {
             mintNewCoins();
        }
        super._transfer(sender, recipient, amount);
    }

    // ################################################
    // ############   MINT FUNCTONS    ############
    // ################################################

    function isMintingPossible() internal returns (bool) {
        if ( mintingActivated && Current_Cycle <= 77 && _getElapsedBlocks(block.number, previousMintBlock) > CYCLE_BLOCKS ) {
            uint newCycle = add(Current_Cycle,uint256(1),'Overflow');
            Current_Cycle = newCycle;                                                    // CURRENT CYCLE IS UPDATED 
            // emit NewCycle(prevCycle, Current_Cycle, block.number, now);
            return true;
        }
        else {
            return false;
        }
    }

    function mintCoins() external returns (bool) {
        if (isMintingPossible() ) {
            mintNewCoins();
            return true;
        }
        return false;
    }

    function mintNewCoins() internal returns (bool) {

        if ( Current_Era < _CalculateCurrentEra() ) {
            Current_Era = add(Current_Era,uint256(1),"NEW ERA : Addition gave error");
            currentDivisibilityFactor = _eras[Current_Era].divisibilityFactor;
            emit NewEra(Current_Era, block.number, now);
        }

        uint currentSupply = totalSupply();
        uint256 newCoins = currentSupply.div(currentDivisibilityFactor);                // Calculate the number of new tokens to be minted.
        uint newmintSpeed = newCoins.div(CYCLE_BLOCKS);                                         // mint speed, i.e tokens minted per block rate for this cycle
        mintSnapshot  memory currentMintSnapshot = mintSnapshot({ cycle:Current_Cycle, era:Current_Era, inflationRate: currentDivisibilityFactor, mintedAmount:newCoins, mintSpeed:newmintSpeed, newTotalSupply:totalSupply(), minter: msg.sender, blockNumber: block.number });

        if (newCoins > prize_amount) {
            newCoins = newCoins.sub(prize_amount);
        }  
        else {
            prize_amount = uint(0);
        }

        _mint( msg.sender, prize_amount );                                                          // PRIZE AMOUNT AWARDED TO THE MINTER
        _mint( SpeedController, newCoins );                                                          // NEWLY MINTED SIGH TRANSFERRED TO SIGH SPEED CONTROLLER
        
        currentMintSnapshot.newTotalSupply = totalSupply();
        mintSnapshots.push(currentMintSnapshot);                                                    // MINT SNAPSHOT ADDED TO THE ARRAY

        previousMintBlock = block.number;        

        emit SIGHMinted(currentMintSnapshot.minter, currentMintSnapshot.cycle, currentMintSnapshot.era, currentMintSnapshot.inflationRate, currentMintSnapshot.mintedAmount, currentMintSnapshot.mintSpeed, currentMintSnapshot.newTotalSupply,currentMintSnapshot.blockNumber );
        return true;        
    }

    function _getElapsedBlocks(uint256 currentBlock , uint256 prevBlock) internal pure returns(uint256) {
        uint deltaBlocks = sub(currentBlock,prevBlock,"GetElapsedBlocks: Subtraction Underflow");
        return deltaBlocks;
    }

    function _CalculateCurrentEra() internal view returns (uint256) {

        if (Current_Cycle <= 7 && Current_Cycle >= 0 ) {
            return uint256(0);
        }

        uint256 C_Era_sub = sub(Current_Cycle,uint256(7),'ERA: Subtraction gave error');
        uint256 _newEra = div(C_Era_sub,uint256(7),"ERA : Division gave error");

        if (_newEra <= 9 ) {
            return uint256(_newEra.add(1) );
        }

        return uint256(11);
    }

    // ################################################
    // ############   BURN FUNCTON    #################
    // ################################################
    
    function burn(uint amount) external returns (bool) {
        require( msg.sender == treasury,"Only Treasury can burn SIGH Tokens");
        _burn(treasury,amount) ;
        uint total_amount_burnt = add(totalAmountBurnt , amount, 'burn : Total Number of tokens burnt gave addition overflow');
        totalAmountBurnt = total_amount_burnt;
        emit SIGHBurned( amount, totalAmountBurnt, totalSupply(), block.number );
        return true;
    }    

    // ################################################
    // ###########   MINT FUNCTONS (VIEW)   ###########
    // ################################################

    function isMintingActivated() external view returns(bool) {
        if (Current_Cycle > 77) {
            return false;
        }
        return mintingActivated;
    }

   function getCurrentEra() public view returns (uint256) {
        return Current_Era;
    }

   function getCurrentCycle() public view returns (uint256) {
        return Current_Cycle;
    }
    
    function getCurrentInflationRate() external view returns (uint256) {
        if (Current_Cycle > 77 || !mintingActivated) {
            return uint(0);
        }
        return currentDivisibilityFactor;
    }
    
    function getBlocksRemainingToMint() external view returns (uint) {

        if (Current_Cycle > 77 || !mintingActivated) {
            return uint(-1);
        }

        uint deltaBlocks = _getElapsedBlocks(block.number, previousMintBlock);

        if (deltaBlocks >= CYCLE_BLOCKS ) {
            return uint(0);
        }
        return CYCLE_BLOCKS.sub(deltaBlocks);
    }


    function getMintSnapshotForCycle(uint cycleNumber) public view returns (uint era,uint inflationRate, uint mintedAmount,uint mintSpeed, uint newTotalSupply,address minter, uint blockNumber ) {
        return ( mintSnapshots[cycleNumber].era,
                 mintSnapshots[cycleNumber].inflationRate,
                 mintSnapshots[cycleNumber].mintedAmount,
                 mintSnapshots[cycleNumber].mintSpeed,
                 mintSnapshots[cycleNumber].newTotalSupply,
                 mintSnapshots[cycleNumber].minter,
                 mintSnapshots[cycleNumber].blockNumber
                 );
    }
    
    function getCurrentMintSpeed() external view returns (uint) {
        if (Current_Cycle > 77 || !mintingActivated) {
            return uint(0);
        }
        uint currentSupply = totalSupply();
        uint256 newCoins = currentSupply.div(currentDivisibilityFactor);                        // Calculate the number of new tokens to be minted.
        uint newmintSpeed = newCoins.div(CYCLE_BLOCKS);                                         // mint speed, i.e tokens minted per block rate for this cycle
        return newmintSpeed;
    }

    function getTotalSighBurnt() external view returns (uint) {
        return totalAmountBurnt;
    }

   function getSpeedController() external view returns (address) {
        return SpeedController;
    }
    
   function getTreasury() external view returns (address) {
        return treasury;
    }
    
    
    // ##################################################################
    // ###########   nternal helper functions for safe math   ###########
    // ##################################################################

    function add(uint a, uint b, string memory errorMessage) internal pure returns (uint) {
        uint c = a + b;
        require(c >= a, errorMessage);
        return c;
    }

    function sub(uint a, uint b, string memory errorMessage) internal pure returns (uint) {
        require(b <= a, errorMessage);
        uint c = a - b;
        return c;
    }

    function mul(uint a, uint b, string memory errorMessage) internal pure returns (uint) {
        if (a == 0) {
        return 0;
        }
        uint c = a * b;
        require(c / a == b, errorMessage);
        return c;
    }

    function min(uint a, uint b) internal pure returns (uint) {
        if (a <= b) {
        return a;
        } else {
        return b;
        }
    }    

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        // Solidity only automatically asserts when dividing by 0
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

}









