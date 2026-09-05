module local_fixture::assets;

use sui::coin::{Self, TreasuryCap};

public struct ASSETS has drop {}
public struct Collectible has key, store { id: UID }

fun init(witness: ASSETS, ctx: &mut TxContext) {
    let (treasury, metadata) = coin::create_currency(
        witness, 6, b"FIX", b"Local fixture", b"Localnet test only", option::none(), ctx,
    );
    transfer::public_transfer(treasury, ctx.sender());
    transfer::public_freeze_object(metadata);
    transfer::public_transfer(Collectible { id: object::new(ctx) }, ctx.sender());
}

public entry fun mint(treasury: &mut TreasuryCap<ASSETS>, amount: u64, recipient: address, ctx: &mut TxContext) {
    transfer::public_transfer(coin::mint(treasury, amount, ctx), recipient);
}

public entry fun create_collectible(recipient: address, ctx: &mut TxContext) {
    transfer::public_transfer(Collectible { id: object::new(ctx) }, recipient);
}
