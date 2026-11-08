# 64. Master Data Historical Semantics — v1.8

## Core rule
If a master row has never been referenced, it may follow the existing hard-delete rule. Once referenced, it cannot be hard-deleted and its **structural business meaning** cannot be mutated.

Structural examples: Position Unit/Team/Group; Department Team parent Unit; Interview Format room/link requirements; Document Type scope/code. To change structural meaning, create a new row and mark old row Inactive.

## Allowed corrections
Display-label typo/translation corrections may be allowed with optimistic version + audit when they do not change business meaning.

## Inactive semantics
Inactive prevents new selection. Historical records keep the reference and remain readable/operable. An Interview using a format later made inactive can still be cancelled/reactivated/processed as long as the format reference itself is unchanged.

## Room historical-identity policy
A Room already referenced by Interview history cannot be repurposed by changing identity-bearing fields such as room `code` or `building` in a way that changes meaning. Create a new Room and Inactive the old one for a real location change. Typo-only display correction may be allowed with audit when owner accepts historical label correction.
