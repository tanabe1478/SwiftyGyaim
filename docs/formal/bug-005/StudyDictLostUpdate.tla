---- MODULE StudyDictLostUpdate ----
EXTENDS FiniteSets

(***************************************************************************
BUG-005 abstraction

Each client learns one unique entry represented by its identifier.  Disk is
studydict.txt, learned records completed study() calls, and local represents
the pre-fix per-WordSearch snapshots.

SharedMemory = FALSE models the old per-instance read-modify-write design.
SharedMemory = TRUE models the current process-wide static studyDict.  A TLA+
action is atomic, so the latter intentionally assumes study() calls in one IME
process are serialized.
***************************************************************************)

CONSTANTS Instances, InitialDisk, SharedMemory

ASSUME /\ Instances # {}
       /\ IsFiniteSet(Instances)
       /\ InitialDisk \subseteq Instances
       /\ SharedMemory \in BOOLEAN

VARIABLES disk,
          learned,
          local,
          initialized,
          shared,
          sharedLoaded

vars == <<disk, learned, local, initialized, shared, sharedLoaded>>

Init ==
    /\ disk = InitialDisk
    /\ learned = {}
    /\ local = [i \in Instances |-> {}]
    /\ initialized = {}
    /\ shared = {}
    /\ sharedLoaded = FALSE

(***************************************************************************
Old design: every WordSearch loads an independent snapshot.  A later study()
writes that complete snapshot and can erase another instance's learned entry.
***************************************************************************)
SnapshotRead(i) ==
    /\ i \notin initialized
    /\ local' = [local EXCEPT ![i] = disk]
    /\ initialized' = initialized \cup {i}
    /\ UNCHANGED <<disk, learned, shared, sharedLoaded>>

SnapshotStudy(i) ==
    /\ i \in initialized
    /\ i \notin learned
    /\ local' = [local EXCEPT ![i] = @ \cup {i}]
    /\ disk' = local[i] \cup {i}
    /\ learned' = learned \cup {i}
    /\ UNCHANGED <<initialized, shared, sharedLoaded>>

SnapshotNext ==
    \/ \E i \in Instances : SnapshotRead(i)
    \/ \E i \in Instances : SnapshotStudy(i)

(***************************************************************************
Current design: one process-wide static studyDict is loaded once.  Every
instance mutates the same in-memory set before the complete set is saved.
***************************************************************************)
LoadShared ==
    /\ ~sharedLoaded
    /\ shared' = disk
    /\ sharedLoaded' = TRUE
    /\ UNCHANGED <<disk, learned, local, initialized>>

SharedStudy(i) ==
    /\ sharedLoaded
    /\ i \notin learned
    /\ shared' = shared \cup {i}
    /\ disk' = shared \cup {i}
    /\ learned' = learned \cup {i}
    /\ UNCHANGED <<local, initialized, sharedLoaded>>

SharedNext ==
    \/ LoadShared
    \/ \E i \in Instances : SharedStudy(i)

Next == IF SharedMemory THEN SharedNext ELSE SnapshotNext

TypeOK ==
    /\ disk \subseteq Instances
    /\ learned \subseteq Instances
    /\ local \in [Instances -> SUBSET Instances]
    /\ initialized \subseteq Instances
    /\ shared \subseteq Instances
    /\ sharedLoaded \in BOOLEAN

NoLostUpdate == learned \subseteq disk

====
