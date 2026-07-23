---- MODULE DeactivationCommit ----
EXTENDS Naturals

(***************************************************************************
ADR-012 / BUG-001 abstraction

A deactivation is split into the observable order used by GyaimController:
hideWindow() -> fix(client:skipStudy:) -> WordSearch.finish().

UseSenderArgument = FALSE models the historical call to fix() without passing
deactivateServer's sender.  UseClientFallback controls whether fix() may use
self.client() when the sender is absent or is not an IMKTextInput.
***************************************************************************)

CONSTANTS ClientScenarios,
          UseSenderArgument,
          UseClientFallback,
          SkipStudyOnDeactivate

ASSUME /\ ClientScenarios \subseteq {"sender", "fallback", "both", "none"}
       /\ ClientScenarios # {}
       /\ UseSenderArgument \in BOOLEAN
       /\ UseClientFallback \in BOOLEAN
       /\ SkipStudyOnDeactivate \in BOOLEAN

VARIABLES phase,
          clientScenario,
          preedit,
          committed,
          studied,
          windowVisible,
          resourceActive,
          commitCount

vars == <<phase, clientScenario, preedit, committed, studied,
          windowVisible, resourceActive, commitCount>>

SenderAvailable(scenario) == scenario \in {"sender", "both"}
FallbackAvailable(scenario) == scenario \in {"fallback", "both"}

EnvironmentClientAvailable ==
    SenderAvailable(clientScenario) \/ FallbackAvailable(clientScenario)

ResolvedClientAvailable ==
    (UseSenderArgument /\ SenderAvailable(clientScenario))
    \/ (UseClientFallback /\ FallbackAvailable(clientScenario))

Init ==
    /\ phase = "active"
    /\ clientScenario \in ClientScenarios
    /\ preedit = TRUE
    /\ committed = FALSE
    /\ studied = FALSE
    /\ windowVisible = TRUE
    /\ resourceActive = TRUE
    /\ commitCount = 0

HideWindow ==
    /\ phase = "active"
    /\ phase' = "hidden"
    /\ windowVisible' = FALSE
    /\ UNCHANGED <<clientScenario, preedit, committed, studied,
                   resourceActive, commitCount>>

FixComposition ==
    /\ phase = "hidden"
    /\ phase' = "fixed"
    /\ preedit' = FALSE
    /\ committed' = (committed \/ (preedit /\ ResolvedClientAvailable))
    /\ studied' = (studied \/
          (preedit /\ ResolvedClientAvailable /\ ~SkipStudyOnDeactivate))
    /\ commitCount' = commitCount +
          IF preedit /\ ResolvedClientAvailable THEN 1 ELSE 0
    /\ UNCHANGED <<clientScenario, windowVisible, resourceActive>>

FinishResources ==
    /\ phase = "fixed"
    /\ phase' = "finished"
    /\ resourceActive' = FALSE
    /\ UNCHANGED <<clientScenario, preedit, committed, studied,
                   windowVisible, commitCount>>

Next == HideWindow \/ FixComposition \/ FinishResources

TypeOK ==
    /\ phase \in {"active", "hidden", "fixed", "finished"}
    /\ clientScenario \in ClientScenarios
    /\ preedit \in BOOLEAN
    /\ committed \in BOOLEAN
    /\ studied \in BOOLEAN
    /\ windowVisible \in BOOLEAN
    /\ resourceActive \in BOOLEAN
    /\ commitCount \in 0..1

NoInputLoss ==
    (phase \in {"fixed", "finished"} /\ EnvironmentClientAvailable)
        => committed

NoUnintentionalStudy == ~studied

WindowHiddenBeforeFix ==
    (phase \in {"fixed", "finished"}) => ~windowVisible

ResourcesFinishAfterFix ==
    (phase # "finished") => resourceActive

AtMostOneCommit == commitCount <= 1

====
