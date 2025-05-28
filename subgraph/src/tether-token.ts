import {
  Issue as IssueEvent,
  Redeem as RedeemEvent,
  Deprecate as DeprecateEvent,
  Params as ParamsEvent,
  DestroyedBlackFunds as DestroyedBlackFundsEvent,
  AddedBlackList as AddedBlackListEvent,
  RemovedBlackList as RemovedBlackListEvent,
  Approval as ApprovalEvent,
  Transfer as TransferEvent,
  Pause as PauseEvent,
  Unpause as UnpauseEvent
} from "../generated/TetherToken/TetherToken"
import {
  Issue,
  Redeem,
  Deprecate,
  Params,
  DestroyedBlackFunds,
  AddedBlackList,
  RemovedBlackList,
  Approval,
  Transfer,
  Pause,
  Unpause
} from "../generated/schema"

export function handleIssue(event: IssueEvent): void {
  let entity = new Issue(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.amount = event.params.amount

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleRedeem(event: RedeemEvent): void {
  let entity = new Redeem(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.amount = event.params.amount

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleDeprecate(event: DeprecateEvent): void {
  let entity = new Deprecate(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.newAddress = event.params.newAddress

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleParams(event: ParamsEvent): void {
  let entity = new Params(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.feeBasisPoints = event.params.feeBasisPoints
  entity.maxFee = event.params.maxFee

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleDestroyedBlackFunds(
  event: DestroyedBlackFundsEvent
): void {
  let entity = new DestroyedBlackFunds(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity._blackListedUser = event.params._blackListedUser
  entity._balance = event.params._balance

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleAddedBlackList(event: AddedBlackListEvent): void {
  let entity = new AddedBlackList(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity._user = event.params._user

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleRemovedBlackList(event: RemovedBlackListEvent): void {
  let entity = new RemovedBlackList(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity._user = event.params._user

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleApproval(event: ApprovalEvent): void {
  let entity = new Approval(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.owner = event.params.owner
  entity.spender = event.params.spender
  entity.value = event.params.value

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleTransfer(event: TransferEvent): void {
  let entity = new Transfer(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.from = event.params.from
  entity.to = event.params.to
  entity.value = event.params.value

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handlePause(event: PauseEvent): void {
  let entity = new Pause(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleUnpause(event: UnpauseEvent): void {
  let entity = new Unpause(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}
