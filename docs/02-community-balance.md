# Community Balance profile system

The **official**, Tripwire-supported modding surface. Unlike everything else in
this kit it needs no injection and no UE4SS.

## Files

```
DeceiveInc\CommunityBalanceProfile.json          <- the active profile
DeceiveInc\CommunityBalanceReport.txt            <- regenerated every server start
DeceiveInc\Community Balance Template\
    CommunityBalanceConfigurationCatalog.json    <- annotated reference (1.4 MB)
    CommunityBalanceProfile.default.json         <- shipped baseline (494 KB)
```

Also accepts `-CommunityBalanceProfile=<path>` on the command line.

## Format

```json
{
  "format": "DeceiveCommunityBalanceProfile",
  "schemaVersion": 1,
  "profileName": "Glass Cannon",
  "overrides": [
    { "table": "DT_Balancing_HitscanWeapons",
      "row":   "Ace_Weapon_Base",
      "field": "DamageBehaviors[BehaviorName=Default].Damage",
      "value": 64 }
  ]
}
```

Limits: 1 MB, 2048 overrides, identifiers up to 128 chars, numeric magnitude up
to 1e8.

## Scope — the important part

It manages **37 tables only**, all spy/weapon/gadget balance. The list is
identical in both the catalog and the shipped baseline:

```
DT_<Spy>_ActivesBalancing / _PassivesBalancing   (Ace, Cavaliere, Chavez, Hans,
    Larcin, Octo, Sasori, Socialite, Squire, Vigil, Xiu, Yumi)
DT_Balancing_HitscanWeapons     DT_Balancing_Projectiles
DT_Balancing_SpawnerWeapons     DT_Projectiles_Balancing
DT_Gadgets_Balancing            DT_SpyShared_ActiveCooldown
DT_SpyShared_HealthPool         DT_SpyShared_StatusEffectsBalancing
```

Anything else is rejected outright:
`Balancing payload references unmanaged table {%s}`.
Fields are gated too — only a "Recommended" allowlist is accepted.

So **lobby wait time, room loot, gamblebox rates, suspicion and map selection
are all out of reach here.** That limitation is what pushed this project toward
UE4SS.

## The report is a useful oracle

`CommunityBalanceReport.txt` distinguishes failure modes precisely:

```
the table does not exist
the row does not exist
the field is not on the Recommended allowlist
field is not a Recommended scalar or boolean type
field name is ambiguous
```

Because "unknown table" and "unknown row" are *different* messages, you can
probe whether a table exists by referencing it with a deliberately bogus row
and reading the report. Useful for exploring with no injection at all.

## Verifying a profile applied

```
Result: applied 286 override(s), skipped 0, clamped 0.
No issues found.
```

The server also pops a balance-report window on start. Changes only take effect
on restart.
