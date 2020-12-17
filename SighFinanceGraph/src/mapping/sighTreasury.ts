import { Address, BigDecimal, BigInt, log } from "@graphprotocol/graph-ts"
import { InstrumentInitialized, InstrumentDistributionInitialized, InstrumentDistributionReset, 
  instrumentBeingDistributedChanged, DripSpeedChanged,AmountDripped,maxTransferAmountUpdated,
  SIGHTransferred, TokensBought, TokensSold, SIGHBurnAllowedSwitched, SIGH_Burned, SIGHBurnSpeedChanged } from "../../generated/SIGHTreasury/SIGHTreasury"

  import { SIGHTreasuryState,TreasurySupportedInstruments, SIGH_Instrument } from "../../generated/schema"
  import { ERC20Detailed } from '../../generated/Lending_Pool_Core/ERC20Detailed'



// NEW 'INSTRUMENT' BEING INITIALIZED BY THE TREASURY
  export function handleInstrumentInitialized(event: InstrumentInitialized): void {
    let SighTreasury = SIGHTreasuryState.load(event.address.toHexString())
    if (SighTreasury == null) {
      SighTreasury = createSighTreasury(event.address.toHexString())
      SighTreasury.address = event.address
    }

    // Storing Tx Hash
    let prevHashes = SighTreasury.instrumentInitializedTxHashes
    prevHashes.push( event.transaction.hash )
    SighTreasury.instrumentInitializedTxHashes = prevHashes

    let supportedInstrument = TreasurySupportedInstruments.load( event.params.instrument.toHexString() )
    if (supportedInstrument == null) {
      supportedInstrument = createTreasurySupportedInstruments(event.params.instrument.toHexString())
      supportedInstrument.address = event.params.instrument
      supportedInstrument.sighTreasury = event.address.toHexString()
    }
    let decimalAdj = BigInt.fromI32(10).pow(supportedInstrument.decimals.toI32() as u8).toBigDecimal()

    supportedInstrument.isInitialized = true;
    supportedInstrument.balanceInTreasury = event.params.balance.toBigDecimal().div( decimalAdj ) ;
    supportedInstrument.totalAmountDripped = event.params.totalAmountDripped.toBigDecimal().div( decimalAdj ) ;
    supportedInstrument.totalAmountTransferred = event.params.totalAmountTransferred.toBigDecimal().div( decimalAdj ) ;

    supportedInstrument.save()
    SighTreasury.save()
  }



// NEW 'INSTRUMENT DISTRIBUTION' BEING INITIALIZED BY THE TREASURY
  export function handleInstrumentDistributionInitialized(event: InstrumentDistributionInitialized): void {
    let SighTreasury = SIGHTreasuryState.load(event.address.toHexString())
    if (SighTreasury == null) {
      SighTreasury = createSighTreasury(event.address.toHexString())
      SighTreasury.address = event.address
    }

    // Storing Tx Hash
    let prevHashes = SighTreasury.instrumentDistributionInitializedTxHashes
    prevHashes.push( event.transaction.hash )
    SighTreasury.instrumentDistributionInitializedTxHashes = prevHashes

    SighTreasury.isDripAllowed = event.params.isDripAllowed

    let supportedInstrument = TreasurySupportedInstruments.load( event.params.instrumentBeingDripped.toHexString() )
    let decimalAdj = BigInt.fromI32(10).pow(supportedInstrument.decimals.toI32() as u8).toBigDecimal()

    SighTreasury.targetAddressForDripping = event.params.targetAddressForDripping
    SighTreasury.instrumentBeingDrippedAddress = event.params.instrumentBeingDripped
    SighTreasury.instrumentBeingDrippedSymbol = supportedInstrument.symbol
    SighTreasury.DripSpeed = event.params.dripSpeed.toBigDecimal().div( decimalAdj ) ;

    supportedInstrument.isBeingDripped = true;
    supportedInstrument.DripSpeed = SighTreasury.DripSpeed;

    supportedInstrument.save()
    SighTreasury.save()
  }




  // 'INSTRUMENT DISTRIBUTION' BEING RESET BY THE TREASURY
  export function handleInstrumentDistributionReset(event: InstrumentDistributionReset): void {
    let SighTreasury = SIGHTreasuryState.load(event.address.toHexString())

    // Storing Tx Hash
    let prevHashes = SighTreasury.instrumentDistributionResetTxHashes
    prevHashes.push( event.transaction.hash )
    SighTreasury.instrumentDistributionResetTxHashes = prevHashes

    SighTreasury.isDripAllowed = event.params.isDripAllowed
    let supportedInstrument = TreasurySupportedInstruments.load( SighTreasury.instrumentBeingDrippedAddress.toHexString() )

    SighTreasury.targetAddressForDripping = event.params.targetAddressForDripping
    SighTreasury.instrumentBeingDrippedAddress = event.params.instrumentBeingDripped
    SighTreasury.instrumentBeingDrippedSymbol = null
    SighTreasury.DripSpeed = event.params.dripSpeed.toBigDecimal();

    supportedInstrument.isBeingDripped = event.params.isDripAllowed;
    supportedInstrument.DripSpeed = SighTreasury.DripSpeed;

    supportedInstrument.save()
    SighTreasury.save()
  }




  // INSTRUMENT BEING DISTRIBUTED CHANGED BY THE TREASURY
  export function handleinstrumentBeingDistributedChanged(event: instrumentBeingDistributedChanged): void {
    let SighTreasury = SIGHTreasuryState.load(event.address.toHexString())

    // Storing Tx Hash
    let prevHashes = SighTreasury.instrumentForDistributionChangedTxHashes
    prevHashes.push( event.transaction.hash )
    SighTreasury.instrumentForDistributionChangedTxHashes = prevHashes
         
    let prevSupportedInstrument = TreasurySupportedInstruments.load( SighTreasury.instrumentBeingDrippedAddress.toHexString() )
    prevSupportedInstrument.isBeingDripped = false
    prevSupportedInstrument.DripSpeed = BigDecimal.fromString('0')

    let supportedInstrument = TreasurySupportedInstruments.load( event.params.newInstrumentToBeDripped.toHexString() )
    let decimalAdj = BigInt.fromI32(10).pow(supportedInstrument.decimals.toI32() as u8).toBigDecimal()

    SighTreasury.instrumentBeingDrippedAddress = event.params.newInstrumentToBeDripped
    SighTreasury.instrumentBeingDrippedSymbol = supportedInstrument.symbol
    SighTreasury.DripSpeed = event.params.dripSpeed.toBigDecimal().div( decimalAdj ) ;

    supportedInstrument.isBeingDripped = true;
    supportedInstrument.DripSpeed = SighTreasury.DripSpeed;

    prevSupportedInstrument.save()
    supportedInstrument.save()
    SighTreasury.save()
  }



  // DISTRIBUTION SPEED CHANGED BY THE TREASURY
  export function handleDripSpeedChanged(event: DripSpeedChanged): void {
    let SighTreasury = SIGHTreasuryState.load(event.address.toHexString())

    // Storing Tx Hash
    let prevHashes = SighTreasury.instrumentDistributionSpeedChangedTxHashes
    prevHashes.push( event.transaction.hash )
    SighTreasury.instrumentDistributionSpeedChangedTxHashes = prevHashes

    let supportedInstrument = TreasurySupportedInstruments.load( SighTreasury.instrumentBeingDrippedAddress.toHexString() )
    let decimalAdj = BigInt.fromI32(10).pow(supportedInstrument.decimals.toI32() as u8).toBigDecimal()

    SighTreasury.DripSpeed = event.params.curDripSpeed.toBigDecimal().div( decimalAdj ) ;
    supportedInstrument.DripSpeed = SighTreasury.DripSpeed

    supportedInstrument.save()
    SighTreasury.save()
  }



  // INSTRUMENT DISTRIBUTED BY THE TREASURY
  export function handleAmountDripped(event: AmountDripped): void {
    let supportedInstrument = TreasurySupportedInstruments.load( event.params.instrumentBeingDripped.toHexString() )

    // Storing Tx Hash
    let prevHashes = supportedInstrument.instrumentDrippedTxHashes
    prevHashes.push( event.transaction.hash )
    supportedInstrument.instrumentDrippedTxHashes = prevHashes

    let decimalAdj = BigInt.fromI32(10).pow(supportedInstrument.decimals.toI32() as u8).toBigDecimal()
    supportedInstrument.balanceInTreasury = event.params.currentBalance.toBigDecimal().div( decimalAdj )
    supportedInstrument.totalAmountDripped = event.params.totalAmountDripped.toBigDecimal().div( decimalAdj )

    supportedInstrument.save()
  }



  // INSTRUMENT BOUGHT BY THE TREASURY
  export function handleTokensBought(event: TokensBought): void {
    let supportedInstrument = TreasurySupportedInstruments.load( event.params.instrument_address.toHexString() )

    // Storing Tx Hash
    let prevHashes = supportedInstrument.instrumentBoughtTxHashes
    prevHashes.push( event.transaction.hash )
    supportedInstrument.instrumentBoughtTxHashes = prevHashes

    let decimalAdj = BigInt.fromI32(10).pow(supportedInstrument.decimals.toI32() as u8).toBigDecimal()
    supportedInstrument.balanceInTreasury = event.params.new_balance.toBigDecimal().div( decimalAdj )
    supportedInstrument.save()
  }




  // INSTRUMENT SOLD BY THE TREASURY
  export function handleTokensSold(event: TokensSold): void {
    let supportedInstrument = TreasurySupportedInstruments.load( event.params.instrument_address.toHexString() )

    // Storing Tx Hash
    let prevHashes = supportedInstrument.instrumentSoldTxHashes
    prevHashes.push( event.transaction.hash )
    supportedInstrument.instrumentSoldTxHashes = prevHashes

    let decimalAdj = BigInt.fromI32(10).pow(supportedInstrument.decimals.toI32() as u8).toBigDecimal()
    supportedInstrument.balanceInTreasury = event.params.new_balance.toBigDecimal().div( decimalAdj )
    supportedInstrument.save()
  }


// MAX SIGH AMOUNT THAT CAN BE TRANSFERRED IS UPDATED
export function handlemaxTransferAmountUpdated(event: maxTransferAmountUpdated): void {
  let SighTreasury = SIGHTreasuryState.load(event.address.toHexString())

  let supportedInstrument = TreasurySupportedInstruments.load('0x043906ab5a1ba7a5c52ff2ef839d2b0c2a19ceba')
  let decimalAdj = BigInt.fromI32(10).pow(supportedInstrument.decimals.toI32() as u8).toBigDecimal()

  SighTreasury.sighMaxTransferLimit = event.params.newmaxTransferLimit.toBigDecimal().div( decimalAdj )
  supportedInstrument.balanceInTreasury = event.params.sighBalance.toBigDecimal().div( decimalAdj )

  SighTreasury.save()
  supportedInstrument.save()
}



  // SIGH TRANSFERRED
  export function handleSIGHTransferred(event: SIGHTransferred): void {
    let SighTreasury = SIGHTreasuryState.load(event.address.toHexString())

    // Storing Tx Hash
    let prevHashes = SighTreasury.sighTransferredTxHashes
    prevHashes.push( event.transaction.hash )
    SighTreasury.sighTransferredTxHashes = prevHashes
    
    let supportedInstrument = TreasurySupportedInstruments.load('0x043906ab5a1ba7a5c52ff2ef839d2b0c2a19ceba')
    let decimalAdj = BigInt.fromI32(10).pow(supportedInstrument.decimals.toI32() as u8).toBigDecimal()
    supportedInstrument.totalAmountTransferred = supportedInstrument.totalAmountTransferred.plus( event.params.amountTransferred.toBigDecimal().div(decimalAdj) ) 

    SighTreasury.save()
    supportedInstrument.save()
  }



  export function handleSIGHBurnAllowedSwitched(event: SIGHBurnAllowedSwitched): void {
    let SighTreasury = SIGHTreasuryState.load(event.address.toHexString())
    if (SighTreasury == null) {
      SighTreasury = createSighTreasury(event.address.toHexString())
      SighTreasury.address = event.address
    }
    // Storing Tx Hash
    let prevHashes = SighTreasury.sighBurnAllowedSwitchedTxHashes
    prevHashes.push( event.transaction.hash )
    SighTreasury.sighBurnAllowedSwitchedTxHashes = prevHashes

    SighTreasury.isSIGHBurnAllowed = event.params.newBurnAllowed
    SighTreasury.save()
  }

  export function handleSIGHBurnSpeedChanged(event: SIGHBurnSpeedChanged): void {
    let decimalAdj = BigInt.fromI32(10).pow(18 as u8).toBigDecimal()

    let SighTreasury = SIGHTreasuryState.load(event.address.toHexString())
    if (SighTreasury == null) {
      SighTreasury = createSighTreasury(event.address.toHexString())
      SighTreasury.address = event.address
    }

    // Storing Tx Hash
    let prevHashes = SighTreasury.sighBurnSpeedChangedTxHashes
    prevHashes.push( event.transaction.hash )
    SighTreasury.sighBurnSpeedChangedTxHashes = prevHashes

    SighTreasury.SIGHBurnSpeed = event.params.newSpeed.toBigDecimal().div(decimalAdj)
    SighTreasury.save()

    let sighInstrument = SIGH_Instrument.load('0x043906ab5a1ba7a5c52ff2ef839d2b0c2a19ceba')
    sighInstrument.currentBurnSpeed_WEI = event.params.newSpeed
    sighInstrument.currentBurnSpeed = SighTreasury.SIGHBurnSpeed
    sighInstrument.save()
  }

  export function handleSIGH_Burned(event: SIGH_Burned): void {
    let decimalAdj = BigInt.fromI32(10).pow(18 as u8).toBigDecimal()

    let SighTreasury = SIGHTreasuryState.load(event.address.toHexString())
    if (SighTreasury == null) {
      SighTreasury = createSighTreasury(event.address.toHexString())
      SighTreasury.address = event.address
    }

    // Storing Tx Hash
    let prevHashes = SighTreasury.sighBurnedTxHashes
    prevHashes.push( event.transaction.hash )
    SighTreasury.sighBurnedTxHashes = prevHashes

    SighTreasury.totalBurntSIGH = event.params.amount.toBigDecimal().div(decimalAdj)
    SighTreasury.save()
  }







// ############################################
// ###########   CREATING ENTITIES   ##########
// ############################################ 

function createSighTreasury(addressID: string): SIGHTreasury {
    let Sigh_Treasury = new SIGHTreasury(addressID)
    let Sigh_Treasury_contract = SIGHTreasuryContract.bind(Address.fromString(addressID))

    Sigh_Treasury.sightroller_address = Sigh_Treasury_contract.sightroller_address()
    Sigh_Treasury.sigh_token = Sigh_Treasury_contract.sigh_token()

    Sigh_Treasury.maxTransferAmount = new BigInt(0)    

    Sigh_Treasury.tokenBeingDripped = Address.fromString('0x0000000000000000000000000000000000000000',)
    Sigh_Treasury.DripSpeed = new BigInt(0)    
    Sigh_Treasury.isDripAllowed = false    

    Sigh_Treasury.recentlySIGHBurned = new BigInt(0)    
    Sigh_Treasury.totalSIGHBurned = new BigInt(0)    

    Sigh_Treasury.save()
    return Sigh_Treasury as SIGHTreasury
}
  
function createTokenBalances(addressID: string) : TokenBalancesData {
    let Token_Balances = new TokenBalancesData(addressID)
    let ERC20_contract = cERC20.bind(Address.fromString(addressID))

    Token_Balances.symbol = ERC20_contract.symbol()
    Token_Balances.balance = new BigInt(0)  
    Token_Balances.totalDripped = new BigInt(0) 
    
    return Token_Balances as TokenBalancesData
}


function createTreasurySupportedInstruments(addressID: string) : TreasurySupportedInstruments {
  let newInstrument = new TreasurySupportedInstruments(addressID);

  return newInstrument as TreasurySupportedInstruments
}