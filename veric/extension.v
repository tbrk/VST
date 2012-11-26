Load loadpath.
Require Import msl.predicates_hered.
Require Import veric.sim veric.step_lemmas veric.base veric.expr veric.extspec 
               veric.juicy_extspec.
Require Import ListSet.

Set Implicit Arguments.

(** External function specifications and linking *)

Lemma extfunct_eqdec : forall ef1 ef2 : AST.external_function, 
  {ef1=ef2} + {~ef1=ef2}.
Proof. intros ef1 ef2; repeat decide equality; apply Address.EqDec_int. Qed.

Module TruePropCoercion.
Definition is_true (b: bool) := b=true.
Coercion is_true: bool >-> Sortclass.
End TruePropCoercion.

Import TruePropCoercion.

Notation IN := (ListSet.set_mem extfunct_eqdec).
Notation NOTIN := (fun ef l => ListSet.set_mem extfunct_eqdec ef l = false).
Notation DIFF := (ListSet.set_diff extfunct_eqdec).

Lemma in_diff (ef: AST.external_function) (l r: list AST.external_function) :
  IN ef l -> NOTIN ef r -> IN ef (DIFF l r).
Proof.
simpl; intros H1 H2; apply set_mem_correct2. 
apply set_mem_correct1 in H1.
apply set_mem_complete1 in H2.
apply set_diff_intro; auto.
Qed.

(** Linking external specification [Sigma] with an extension implementing
   functions in [handled] comprises removing the functions in [handled] from
   the external specification. *)

Definition link_ext_spec (M Z: Type) (handled: list AST.external_function) 
  (Sigma: external_specification M AST.external_function Z) :=
  Build_external_specification M AST.external_function Z
    (ext_spec_type Sigma)
    (fun (ef: AST.external_function) (x: ext_spec_type Sigma ef)
         (tys: list typ) (args: list val) (z: Z) (m: M) => 
             if ListSet.set_mem extfunct_eqdec ef handled then False 
             else ext_spec_pre Sigma ef x tys args z m)
    (fun (ef: AST.external_function) (x: ext_spec_type Sigma ef)
         (ty: option typ) (ret: option val) (z: Z) (m: M) => 
             if ListSet.set_mem extfunct_eqdec ef handled then True
             else ext_spec_post Sigma ef x ty ret z m).

Program Definition link_juicy_ext_spec (Z: Type) (handled: list AST.external_function)
  (Sigma: juicy_ext_spec Z) :=
  Build_juicy_ext_spec Z (link_ext_spec handled Sigma) _ _.
Next Obligation.
if_tac; [unfold hereditary; auto|].
generalize JE_pre_hered; unfold hereditary; intros; eapply H; eauto.
Qed.
Next Obligation.
if_tac; [unfold hereditary; auto|].
generalize JE_post_hered; unfold hereditary; intros; eapply H; eauto.
Qed.

(** An external signature [ext_sig] is a list of handled functions together with
   an external specification. *)

Section ExtSig.
Variables M Z: Type.

Inductive ext_sig := 
  mkextsig: forall (functs: list AST.external_function)
                   (extspec: external_specification M external_function Z), 
    ext_sig.

Definition extsig2functs (Sigma: ext_sig) := 
  match Sigma with mkextsig l _ => l end.
Coercion extsig2functs : ext_sig >-> list.

Definition extsig2extspec (Sigma: ext_sig) :=
  match Sigma with mkextsig functs spec => spec end.
Coercion extsig2extspec : ext_sig >-> external_specification.

Definition spec_of (ef: AST.external_function) (Sigma: ext_sig) :=
  (ext_spec_pre Sigma ef, ext_spec_post Sigma ef).

End ExtSig.

Record juicy_ext_sig (Z: Type): Type := mkjuicyextsig {
  JE_functs:> list external_function;
  JE_extspec:> juicy_ext_spec Z
}.

Definition juicy_extsig2extsig (Z: Type) (je: juicy_ext_sig Z) :=
  mkextsig (JE_functs je) (JE_extspec je).
Coercion juicy_extsig2extsig: juicy_ext_sig >-> ext_sig.

Definition link (T Z: Type) (esig: ext_sig T Z) 
      (handled: list AST.external_function) :=
  mkextsig handled (link_ext_spec handled esig).

Definition juicy_link (Z: Type) (jesig: juicy_ext_sig Z) 
      (handled: list AST.external_function) :=
  mkjuicyextsig handled (link_juicy_ext_spec handled jesig).

(** A client signature is linkable with an extension signature when each
   extension function specification ef:{P}{Q} is a subtype of the
   specification ef:{P'}{Q'} assumed by client. *)

Definition linkable (M Z Zext: Type) (proj_zext: Z -> Zext)
      (handled: list AST.external_function) 
      (csig: ext_sig M Z) (ext_sig: ext_sig M Zext) := 
  forall ef P Q P' Q', 
    IN ef (DIFF csig handled) -> 
    spec_of ef ext_sig = (P, Q) -> 
    spec_of ef csig = (P', Q') -> 
    forall x' tys args m z, P' x' tys args z m -> 
      exists x, P x tys args (proj_zext z) m /\
      forall ty ret m' z', Q x ty ret (proj_zext z') m' -> Q' x' ty ret z' m'.

(** * Extensions *)

Module Extension. Section Extension.
 Variables
  (G: Type) (** global environments *)
  (xT: Type) (** corestates of extended semantics *)
  (cT: nat -> Type) (** corestates of core semantics *)
  (M: Type) (** memories *)
  (D: Type) (** initialization data *)
  (Z: Type) (** external states *)
  (Zint: Type) (** portion of Z implemented by extension *)
  (Zext: Type) (** portion of Z external to extension *)

  (esem: CoreSemantics G xT M D) (** extended semantics *)
  (csem: forall i:nat, option (CoreSemantics G (cT i) M D)) (** a set of core semantics *)

  (csig: ext_sig M Z) (** client signature *)
  (esig: ext_sig M Zext) (** extension signature *)
  (handled: list AST.external_function). (** functions handled by this extension *)

 Record Sig := Make {
 (** generalized projection of core [i] from state [s] *)
   proj_core : forall i:nat, xT -> option (cT i);
   core_exists : forall ge i s c' m s' m', 
     corestep esem ge s m s' m' -> proj_core i s' = Some c' -> 
     exists c, proj_core i s = Some c;
   
 (** the active (i.e., currently scheduled) core *)
   active : xT -> nat;
   active_csem : forall s, exists CS, csem (active s) = Some CS;
   active_proj_core : forall s, exists c, proj_core (active s) s = Some c;
   
 (** Runnable=[true] when [active s] is runnable (i.e., not blocked
    waiting on an external function call and not safely halted). *)
   runnable : G -> xT -> bool;
   runnable_false : forall ge s c CS,
     runnable ge s = false -> 
     csem (active s) = Some CS -> proj_core (active s) s = Some c -> 
     (exists rv, safely_halted CS ge c = Some rv) \/
     (exists ef, exists sig, exists args, at_external CS c = Some (ef, sig, args));

 (** A core is no longer "at external" once the extension has returned 
    to it with the result of the call on which it was blocked. *)
   after_at_external_excl : forall i CS c c' ret,
     csem i = Some CS -> after_external CS ret c = Some c' -> 
     at_external CS c' = None;
   
   at_external_csig: forall s i CS c ef args sig,
     csem i = Some CS -> proj_core i s = Some c -> 
     at_external CS c = Some (ef, sig, args) -> 
     IN ef csig;
   notat_external_handled: forall s i CS c ef args sig,
     csem i = Some CS -> proj_core i s = Some c -> 
     at_external CS c = Some (ef, sig, args) -> 
     at_external esem s = None -> 
     IN ef handled;
   at_external_not_handled: forall s ef args sig,
     at_external esem s = Some (ef, sig, args) -> 
     NOTIN ef handled;

 (** Type [xT] embeds [Zint]. *)
   proj_zint: xT -> Zint;
   proj_zext: Z -> Zext;
   zmult: Zint -> Zext -> Z;
   zmult_proj: forall zint zext, proj_zext (zmult zint zext) = zext;

 (** Implemented "external" state is unchanged after truly external calls. *)
   ext_upd_at_external : forall ef sig args ret s s',
     at_external esem s = Some (ef, sig, args) -> 
     after_external esem ret s = Some s' -> 
     proj_zint s = proj_zint s';
   
 (** [esem] and [csem] are signature linkable *)
   esem_csem_linkable: linkable proj_zext handled csig esig
 }.

End Extension. End Extension.

Implicit Arguments Extension.Make [G xT cT M D Z Zint Zext].

(** * Safe Extensions *)

Section AllSafety.
 Variables
  (G: Type) (** global environments *)
  (xT: Type) (** corestates of extended semantics *)
  (cT: nat -> Type) (** corestates of core semantics *)
  (M: Type) (** memories *)
  (D: Type) (** initialization data *)
  (Z: Type) (** external states *)
  (Zint: Type) (** portion of Z implemented by extension *)
  (Zext: Type) (** portion of Z external to extension *)

  (esem: CoreSemantics G xT M D) (** extended semantics *)
  (csem: forall i:nat, option (CoreSemantics G (cT i) M D)) (** a set of core semantics *)

  (csig: ext_sig M Z) (** client signature *)
  (esig: ext_sig M Zext) (** extension signature *)
  (handled: list AST.external_function). (** functions handled by this extension *)

Import Extension.

(** a global invariant characterizing "safe" extensions *)
Definition all_safe (E: Sig cT Zint esem csem csig esig handled)
  (ge: G) (n: nat) (z: Z) (w: xT) (m: M) :=
     forall i CS c, csem i = Some CS -> proj_core E i w = Some c -> 
       safeN CS csig ge n z c m.

(** All-safety implies safeN. *)
Definition safe_extension (E: Sig cT Zint esem csem csig esig handled) :=
  forall ge n s m z, 
    all_safe E ge n (zmult E (proj_zint E s) z) s m -> 
    safeN esem (link esig handled) ge n z s m.

End AllSafety.

Module SafetyInterpolant. Section SafetyInterpolant.
 Variables
  (G: Type) (** global environments *)
  (xT: Type) (** corestates of extended semantics *)
  (cT: nat -> Type) (** corestates of core semantics *)
  (M: Type) (** memories *)
  (D: Type) (** initialization data *)
  (Z: Type) (** external states *)
  (Zint: Type) (** portion of Z implemented by extension *)
  (Zext: Type) (** portion of Z external to extension *)

  (esem: CoreSemantics G xT M D) (** extended semantics *)
  (csem: forall i:nat, option (CoreSemantics G (cT i) M D)) (** a set of core semantics *)

  (csig: ext_sig M Z) (** client signature *)
  (esig: ext_sig M Zext) (** extension signature *)
  (handled: list AST.external_function) (** functions handled by this extension *)
  (E: Extension.Sig cT Zint esem csem csig esig handled). 

Definition proj_zint := E.(Extension.proj_zint). 
Coercion proj_zint : xT >-> Zint.

Definition proj_zext := E.(Extension.proj_zext).
Coercion proj_zext : Z >-> Zext.

Notation ALL_SAFE := (all_safe E).
Notation PROJ_CORE := E.(Extension.proj_core).
Notation "zint \o zext" := (E.(Extension.zmult) zint zext) 
  (at level 66, left associativity). 
Notation ACTIVE := (E.(Extension.active)).
Notation RUNNABLE := (E.(Extension.runnable)).
Notation "'CORE' i 'is' ( CS , c ) 'in' s" := 
  (csem i = Some CS /\ PROJ_CORE i s = Some c)
  (at level 66, no associativity).
Notation core_exists := E.(Extension.core_exists).
Notation active_csem := E.(Extension.active_csem).
Notation active_proj_core := E.(Extension.active_proj_core).
Notation after_at_external_excl := E.(Extension.after_at_external_excl).
Notation notat_external_handled := E.(Extension.notat_external_handled).
Notation at_external_not_handled := E.(Extension.at_external_not_handled).
Notation ext_upd_at_external := E.(Extension.ext_upd_at_external).
Notation runnable_false := E.(Extension.runnable_false).

Inductive safety_interpolant: Type := SafetyInterpolant: forall 
  (** Coresteps preserve the all-safety invariant. *)
  (core_pres: forall ge n z (s: xT) c m CS s' c' m', 
    ALL_SAFE ge (S n) (s \o z) s m -> 
    CORE (ACTIVE s) is (CS, c) in s -> 
    corestep CS ge c m c' m' -> corestep esem ge s m s' m' -> 
    ALL_SAFE ge n (s' \o z) s' m')

  (** Corestates satisfying the invariant can corestep. *)
  (core_prog: forall ge n z s m c CS, 
    ALL_SAFE ge (S n) z s m -> 
    RUNNABLE ge s=true -> CORE (ACTIVE s) is (CS, c) in s -> 
    exists c', exists s', exists m', 
      corestep CS ge c m c' m' /\ corestep esem ge s m s' m' /\
      CORE (ACTIVE s) is (CS, c') in s')

  (** "Handled" steps respect function specifications. *)
  (handled_pres: forall ge s z m (c: cT (ACTIVE s)) s' m' (c': cT (ACTIVE s)) 
      (CS: CoreSemantics G (cT (ACTIVE s)) M D) ef sig args P Q x, 
    let i := ACTIVE s in CORE i is (CS, c) in s -> 
    at_external CS c = Some (ef, sig, args) -> 
    ListSet.set_mem extfunct_eqdec ef handled = true -> 
    spec_of ef csig = (P, Q) -> 
    P x (sig_args sig) args (s \o z) m -> 
    corestep esem ge s m s' m' -> 
    CORE i is (CS, c') in s' -> 
      ((at_external CS c' = Some (ef, sig, args) /\ P x (sig_args sig) args (s' \o z) m' /\
        (forall j, ACTIVE s' = j -> i <> j)) \/
      (exists ret, after_external CS ret c = Some c' /\ Q x (sig_res sig) ret (s' \o z) m')))

  (** "Handled" states satisfying the invariant can step or are safely halted;
     core states that remain "at_external" over handled steps are unchanged. *)
  (handled_prog: forall ge n (z: Zext) (s: xT) m,
    ALL_SAFE ge (S n) (s \o z) s m -> 
    RUNNABLE ge s=false -> 
    at_external esem s = None -> 
    (exists s', exists m', corestep esem ge s m s' m' /\ 
      forall i c CS, CORE i is (CS, c) in s -> 
        exists c', CORE i is (CS, c') in s' /\ 
          (forall ef args ef' args', 
            at_external CS c = Some (ef, args) -> 
            at_external CS c' = Some (ef', args') -> c=c')) \/
    (exists rv, safely_halted esem ge s = Some rv))

  (** Safely halted threads remain halted. *)
  (safely_halted_halted: forall ge s m s' m' i CS c rv,
    CORE i is (CS, c) in s -> 
    safely_halted CS ge c = Some rv -> 
    corestep esem ge s m s' m' -> 
    CORE i is (CS, c) in s')

  (** Safety of other threads is preserved when handling one step of blocked
     thread [i]. *)
  (handled_rest: forall ge s m s' m' c CS,
    CORE (ACTIVE s) is (CS, c) in s -> 
    ((exists ef, exists sig, exists args, at_external CS c = Some (ef, sig, args)) \/ 
      exists rv, safely_halted CS ge c = Some rv) -> 
    at_external esem s = None -> 
    corestep esem ge s m s' m' -> 
    (forall j (CS0: CoreSemantics G (cT j) M D) c0, ACTIVE s <> j ->  
      (CORE j is (CS0, c0) in s' -> CORE j is (CS0, c0) in s) /\
      (forall n z z', CORE j is (CS0, c0) in s -> 
                      safeN CS0 csig ge (S n) (s \o z) c0 m -> 
                      safeN CS0 csig ge n (s' \o z') c0 m')))

  (** If the extended machine is at external, then the active thread is at
     external (an extension only implements external functions, it doesn't
     introduce them). *)
  (at_extern_call: forall s ef sig args,
    at_external esem s = Some (ef, sig, args) -> 
    exists CS, exists c, 
      CORE (ACTIVE s) is (CS, c) in s /\ 
      at_external CS c = Some (ef, sig, args))

  (** Inject the results of an external call into the extended machine state. *)
  (at_extern_ret: forall z s (c: cT (ACTIVE s)) m z' m' tys args ty ret c' CS ef sig x 
      (P: ext_spec_type esig ef -> list typ -> list val -> Zext -> M -> Prop) 
      (Q: ext_spec_type esig ef -> option typ -> option val -> Zext -> M -> Prop),
    CORE (ACTIVE s) is (CS, c) in s -> 
    at_external esem s = Some (ef, sig, args) -> 
    spec_of ef esig = (P, Q) -> 
    P x tys args (s \o z) m -> Q x ty ret z' m' -> 
    after_external CS ret c = Some c' -> 
    exists s': xT, 
      z' = s' \o z' /\
      after_external esem ret s = Some s' /\ 
      CORE (ACTIVE s) is (CS, c') in s')

  (** Safety of other threads is preserved when returning from an external 
     function call. *)
  (at_extern_rest: forall z s (c: cT (ACTIVE s)) m z' s' m' tys args ty ret c' CS ef x sig
      (P: ext_spec_type esig ef -> list typ -> list val -> Zext -> M -> Prop) 
      (Q: ext_spec_type esig ef -> option typ -> option val -> Zext -> M -> Prop),
    CORE (ACTIVE s) is (CS, c) in s -> 
    at_external esem s = Some (ef, sig, args) -> 
    spec_of ef esig = (P, Q) -> 
    P x tys args (s \o z) m -> Q x ty ret z' m' -> 
    after_external CS ret c = Some c' -> 
    after_external esem ret s = Some s' -> 
    CORE (ACTIVE s) is (CS, c') in s' -> 
    (forall j (CS0: CoreSemantics G (cT j) M D) c0, ACTIVE s <> j -> 
      (CORE j is (CS0, c0) in s' -> CORE j is (CS0, c0) in s) /\
      (forall ge n, CORE j is (CS0, c0) in s -> 
                    safeN CS0 csig ge (S n) (s \o z) c0 m -> 
                    safeN CS0 csig ge n (s' \o z') c0 m'))),
  safety_interpolant.

End SafetyInterpolant. End SafetyInterpolant.

Module EXTENSION_SOUNDNESS. Section EXTENSION_SOUNDNESS.
 Variables
  (G: Type) (** global environments *)
  (xT: Type) (** corestates of extended semantics *)
  (cT: nat -> Type) (** corestates of core semantics *)
  (M: Type) (** memories *)
  (D: Type) (** initialization data *)
  (Z: Type) (** external states *)
  (Zint: Type) (** portion of Z implemented by extension *)
  (Zext: Type) (** portion of Z external to extension *)

  (esem: CoreSemantics G xT M D) (** extended semantics *)
  (csem: forall i:nat, option (CoreSemantics G (cT i) M D)) (** a set of core semantics *)

  (csig: ext_sig M Z) (** client signature *)
  (esig: ext_sig M Zext) (** extension signature *)
  (handled: list AST.external_function) (** functions handled by this extension *)
  (E: Extension.Sig cT Zint esem csem csig esig handled). 

Import SafetyInterpolant.

Record Sig := Make {extension_sound: safety_interpolant E -> safe_extension E}.

End EXTENSION_SOUNDNESS. End EXTENSION_SOUNDNESS.
