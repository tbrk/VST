(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(** Correctness proof for Cminor generation. *)

Require Import Coq.Program.Equality.
Require Import FSets.
Require Import Coqlib.
Require Intv.
Require Import Errors.
Require Import Maps.
Require Import AST.
Require Import Integers.
Require Import Floats.
Require Import Values.
Require Import Memdata.
Require Import Memory.
Require Import Events.
Require Import Globalenvs.
Require Import Smallstep.
Require Import Switch.
Require Import Csharpminor.
Require Import Cminor.
Require Import Cminorgen.

Open Local Scope error_monad_scope.

Section TRANSLATION.

Variable prog: Csharpminor.program.
Variable tprog: program.
Hypothesis TRANSL: transl_program prog = OK tprog.
Let ge : Csharpminor.genv := Genv.globalenv prog.
Let tge: genv := Genv.globalenv tprog.

Lemma symbols_preserved:
  forall (s: ident), Genv.find_symbol tge s = Genv.find_symbol ge s.
Proof (Genv.find_symbol_transf_partial transl_fundef _ TRANSL).

Lemma function_ptr_translated:
  forall (b: block) (f: Csharpminor.fundef),
  Genv.find_funct_ptr ge b = Some f ->
  exists tf,
  Genv.find_funct_ptr tge b = Some tf /\ transl_fundef f = OK tf.
Proof (Genv.find_funct_ptr_transf_partial transl_fundef _ TRANSL).

Lemma functions_translated:
  forall (v: val) (f: Csharpminor.fundef),
  Genv.find_funct ge v = Some f ->
  exists tf,
  Genv.find_funct tge v = Some tf /\ transl_fundef f = OK tf.
Proof (Genv.find_funct_transf_partial transl_fundef _ TRANSL).

Lemma varinfo_preserved:
  forall b, Genv.find_var_info tge b = Genv.find_var_info ge b.
Proof (Genv.find_var_info_transf_partial transl_fundef _ TRANSL).

Lemma sig_preserved_body:
  forall f tf cenv size,
  transl_funbody cenv size f = OK tf -> 
  tf.(fn_sig) = Csharpminor.fn_sig f.
Proof.
  intros. unfold transl_funbody in H. monadInv H; reflexivity.
Qed.

Lemma sig_preserved:
  forall f tf,
  transl_fundef f = OK tf -> 
  Cminor.funsig tf = Csharpminor.funsig f.
Proof.
  intros until tf; destruct f; simpl.
  unfold transl_function. destruct (build_compilenv f).
  case (zle z Int.max_unsigned); simpl bind; try congruence.
  intros. monadInv H. simpl. eapply sig_preserved_body; eauto. 
  intro. inv H. reflexivity.
Qed.

(** * Derived properties of memory operations *)

Lemma load_freelist:
  forall fbl chunk m b ofs m',
  (forall b' lo hi, In (b', lo, hi) fbl -> b' <> b) -> 
  Mem.free_list m fbl = Some m' ->
  Mem.load chunk m' b ofs = Mem.load chunk m b ofs.
Proof.
  induction fbl; intros.
  simpl in H0. congruence.
  destruct a as [[b' lo] hi].
  generalize H0. simpl. case_eq (Mem.free m b' lo hi); try congruence.
  intros m1 FR1 FRL. 
  transitivity (Mem.load chunk m1 b ofs).
  eapply IHfbl; eauto. intros. eapply H. eauto with coqlib. 
  eapply Mem.load_free; eauto. left. apply sym_not_equal. eapply H. auto with coqlib. 
Qed.

Lemma perm_freelist:
  forall fbl m m' b ofs k p,
  Mem.free_list m fbl = Some m' ->
  Mem.perm m' b ofs k p ->
  Mem.perm m b ofs k p.
Proof.
  induction fbl; simpl; intros until p.
  congruence.
  destruct a as [[b' lo] hi]. case_eq (Mem.free m b' lo hi); try congruence.
  intros. eauto with mem.
Qed.

Lemma nextblock_freelist:
  forall fbl m m',
  Mem.free_list m fbl = Some m' ->
  Mem.nextblock m' = Mem.nextblock m.
Proof.
  induction fbl; intros until m'; simpl.
  congruence.
  destruct a as [[b lo] hi]. 
  case_eq (Mem.free m b lo hi); intros; try congruence.
  transitivity (Mem.nextblock m0). eauto. eapply Mem.nextblock_free; eauto.
Qed.

Lemma free_list_freeable:
  forall l m m',
  Mem.free_list m l = Some m' ->
  forall b lo hi,
  In (b, lo, hi) l -> Mem.range_perm m b lo hi Cur Freeable.
Proof.
  induction l; simpl; intros.
  contradiction.
  revert H. destruct a as [[b' lo'] hi'].
  caseEq (Mem.free m b' lo' hi'); try congruence.
  intros m1 FREE1 FREE2.
  destruct H0. inv H. 
  eauto with mem.
  red; intros. eapply Mem.perm_free_3; eauto. exploit IHl; eauto.
Qed.

Lemma nextblock_storev:
  forall chunk m addr v m',
  Mem.storev chunk m addr v = Some m' -> Mem.nextblock m' = Mem.nextblock m.
Proof.
  unfold Mem.storev; intros. destruct addr; try discriminate. 
  eapply Mem.nextblock_store; eauto.
Qed.

(** * Correspondence between Csharpminor's and Cminor's environments and memory states *)

(** In Csharpminor, every variable is stored in a separate memory block.
  In the corresponding Cminor code, some of these variables reside in
  the local variable environment; others are sub-blocks of the stack data 
  block.  We capture these changes in memory via a memory injection [f]:
- [f b = None] means that the Csharpminor block [b] no longer exist
  in the execution of the generated Cminor code.  This corresponds to
  a Csharpminor local variable translated to a Cminor local variable.
- [f b = Some(b', ofs)] means that Csharpminor block [b] corresponds
  to a sub-block of Cminor block [b] at offset [ofs].

  A memory injection [f] defines a relation [val_inject f] between
  values and a relation [Mem.inject f] between memory states.
  These relations will be used intensively
  in our proof of simulation between Csharpminor and Cminor executions.

  In this section, we define the relation between
  Csharpminor and Cminor environments. *)

(******
(** Matching for a Csharpminor variable [id].
- If this variable is mapped to a Cminor local variable, the
  corresponding Csharpminor memory block [b] must no longer exist in
  Cminor ([f b = None]).  Moreover, the content of block [b] must
  match the value of [id] found in the Cminor local environment [te].
- If this variable is mapped to a sub-block of the Cminor stack data
  at offset [ofs], the address of this variable in Csharpminor [Vptr b
  Int.zero] must match the address of the sub-block [Vptr sp (Int.repr
  ofs)].
*)

Inductive match_var (f: meminj) (id: ident)
                    (e: Csharpminor.env) (m: mem) (te: env) (sp: block) : 
                    var_info -> Prop :=
  | match_var_local:
      forall chunk b v v',
      PTree.get id e = Some (b, Vscalar chunk) ->
      Mem.load chunk m b 0 = Some v ->
      f b = None ->
      PTree.get (for_var id) te = Some v' ->
      val_inject f v v' ->
      match_var f id e m te sp (Var_local chunk)
  | match_var_stack_scalar:
      forall chunk ofs b,
      PTree.get id e = Some (b, Vscalar chunk) ->
      val_inject f (Vptr b Int.zero) (Vptr sp (Int.repr ofs)) ->
      match_var f id e m te sp (Var_stack_scalar chunk ofs)
  | match_var_stack_array:
      forall ofs sz al b,
      PTree.get id e = Some (b, Varray sz al) ->
      val_inject f (Vptr b Int.zero) (Vptr sp (Int.repr ofs)) ->
      match_var f id e m te sp (Var_stack_array ofs sz al)
  | match_var_global_scalar:
      forall chunk,
      PTree.get id e = None ->
      (forall b gv, Genv.find_symbol ge id = Some b ->
                    Genv.find_var_info ge b = Some gv ->
                    gvar_info gv = Vscalar chunk) ->
      match_var f id e m te sp (Var_global_scalar chunk)
  | match_var_global_array:
      PTree.get id e = None ->
      match_var f id e m te sp (Var_global_array).
*******)

Inductive match_var (f: meminj) (sp: block): option (block * Z) -> option Z -> Prop :=
  | match_var_local: forall b sz ofs,
      val_inject f (Vptr b Int.zero) (Vptr sp (Int.repr ofs)) ->
      match_var f sp (Some(b, sz)) (Some ofs)
  | match_var_global:
      match_var f sp None None.

(** Matching between a Csharpminor environment [e] and a Cminor
  environment [te].  The [lo] and [hi] parameters delimit the range
  of addresses for the blocks referenced from [te]. *)

Record match_env (f: meminj) (cenv: compilenv)
                 (e: Csharpminor.env) (le: Csharpminor.temp_env) (m: mem)
                 (te: env) (sp: block)
                 (lo hi: Z) : Prop :=
  mk_match_env {

(** Csharpminor local variables match sub-blocks of the Cminor stack data block. *)
    me_vars:
      forall id, match_var f sp (e!id) (cenv!id);

(** Temporaries match *)
    me_temps:
      forall id v, le!id = Some v ->
      exists v', te!(id) = Some v' /\ val_inject f v v';

(** [lo, hi] is a proper interval. *)
    me_low_high:
      lo <= hi;

(** Every block appearing in the Csharpminor environment [e] must be
  in the range [lo, hi]. *)
    me_bounded:
      forall id b sz, PTree.get id e = Some(b, sz) -> lo <= b < hi;

(****
(** Distinct Csharpminor local variables must be mapped to distinct blocks. *)
    me_inj:
      forall id1 b1 lv1 id2 b2 lv2,
      PTree.get id1 e = Some(b1, lv1) ->
      PTree.get id2 e = Some(b2, lv2) ->
      id1 <> id2 -> b1 <> b2;
****)

(** All blocks mapped to sub-blocks of the Cminor stack data must be
    images of variables from the Csharpminor environment [e] *)
    me_inv:
      forall b delta,
      f b = Some(sp, delta) ->
      exists id, exists sz, PTree.get id e = Some(b, sz);

(** All Csharpminor blocks below [lo] (i.e. allocated before the blocks
  referenced from [e]) must map to blocks that are below [sp]
  (i.e. allocated before the stack data for the current Cminor function). *)
    me_incr:
      forall b tb delta,
      f b = Some(tb, delta) -> b < lo -> tb < sp;

(** The sizes of blocks appearing in [e] are respected *)
    me_bounds:
      forall id b sz ofs p,
      PTree.get id e = Some(b, sz) -> Mem.perm m b ofs Max p -> 0 <= ofs < sz
  }.

Hint Resolve me_low_high.

(** The remainder of this section is devoted to showing preservation
  of the [match_en] invariant under various assignments and memory
  stores.  First: invariance by changes of memory and injections. *)

Ltac geninv x := 
  let H := fresh in (generalize x; intro H; inv H).

Lemma match_env_invariant:
  forall f1 cenv e le m1 te sp lo hi f2 m2,
  match_env f1 cenv e le m1 te sp lo hi ->
  (forall b ofs p, 
   lo <= b < hi -> Mem.perm m2 b ofs Max p -> Mem.perm m1 b ofs Max p) ->
  inject_incr f1 f2 ->
  (forall b delta, f2 b = Some(sp, delta) -> f1 b = Some(sp, delta)) ->
  (forall b, b < lo -> f2 b = f1 b) ->
  match_env f2 cenv e le m2 te sp lo hi.
Proof.
  intros. destruct H. constructor; auto.
(* vars *)
  intros. geninv (me_vars0 id); econstructor; eauto.
(* temps *)
  intros. exploit me_temps0; eauto. intros [v' [A B]]. exists v'; eauto.
(* bounded *)
  intros. eauto. 
(* below *)
  intros. rewrite H3 in H; eauto.
(* bounds *)
  intros. eauto.
Qed.

(** Preservation by assignment to a Csharpminor temporary and the
  corresponding Cminor local variable. *)

Lemma match_env_set_temp:
  forall f cenv e le m te sp lo hi id v tv,
  val_inject f v tv ->
  match_env f cenv e le m te sp lo hi ->
  match_env f cenv e (PTree.set id v le) m (PTree.set id tv te) sp lo hi.
Proof.
  intros. destruct H0. constructor; auto.
  intros until v0. repeat rewrite PTree.gsspec. destruct (peq id0 id); intros.
  inv H0. exists tv; auto. eauto.
Qed.

(** [match_env] and allocations *)

Lemma match_env_alloc_same:
  forall f1 cenv e le m1 te sp lo m2 b f2 id ofs sz,
  match_env f1 cenv e le m1 te sp lo (Mem.nextblock m1) ->
  Mem.alloc m1 0 sz = (m2, b) ->
  inject_incr f1 f2 ->
  f2 b = Some(sp, ofs) ->
  (forall b', b' <> b -> f2 b' = f1 b') ->
  e!id = None ->
  match_env f2 (PTree.set id ofs cenv) (PTree.set id (b, sz) e) le m2 te sp lo (Mem.nextblock m2).
Proof.
  intros until sz. intros ME ALLOC INCR SAME OTHER ENV.
  inv ME; constructor.
(* vars *)
  intros. repeat rewrite PTree.gsspec. destruct (peq id0 id).
  (* the new var *)
  constructor. econstructor. eauto. rewrite Int.add_commut; rewrite Int.add_zero; auto.
  (* the other vars *)
  geninv (me_vars0 id0); constructor; eauto.
(* temps *)
  intros. exploit me_temps0; eauto. intros [v' [A B]]. 
  exists v'; split; auto. eapply val_inject_incr; eauto.
(* low high *)
  exploit Mem.nextblock_alloc; eauto. unfold block in *; omega.
(* bounded *)
  exploit Mem.alloc_result; eauto. intro RES.
  exploit Mem.nextblock_alloc; eauto. intro NEXT.
  intros until sz0. rewrite PTree.gsspec. destruct (peq id0 id); intro EQ.
  inv EQ. unfold block in *; omega.
  exploit me_bounded0; eauto. unfold block in *; omega.
(* inv *)
  intros. destruct (zeq b0 b). 
  subst. exists id; exists sz. apply PTree.gss.
  exploit me_inv0; eauto. rewrite <- OTHER; eauto.
  intros [id' [lv' A]]. exists id'; exists lv'.
  rewrite PTree.gso; auto. congruence.
(* incr *)
  intros. eapply me_incr0; eauto. rewrite <- OTHER; eauto.
  exploit Mem.alloc_result; eauto. unfold block; omega.
(* bounds *)
  intros. rewrite PTree.gsspec in H.
  exploit Mem.perm_alloc_inv. eexact ALLOC. eauto. 
  destruct (peq id0 id). 
  inv H. rewrite zeq_true. auto. 
  rewrite zeq_false. eauto. 
  apply Mem.valid_not_valid_diff with m1.
  exploit me_bounded0; eauto. intros [A B]. auto. 
  eauto with mem.
Qed.

(*
Lemma match_env_alloc_other:
  forall f1 cenv e le m1 te sp lo hi sz m2 b f2,
  match_env f1 cenv e le m1 te sp lo hi ->
  Mem.alloc m1 0 sz = (m2, b) ->
  inject_incr f1 f2 ->
  (forall b', b' <> b -> f2 b' = f1 b') ->
  hi <= b ->
  match f2 b with None => True | Some(b',ofs) => sp < b' end ->
  match_env f2 cenv e le m2 te sp lo hi.
Proof.
  intros until f2; intros ME ALLOC INCR OTHER BOUND TBOUND.
  inv ME.
  assert (BELOW: forall id b' lv, e!id = Some(b', lv) -> b' <> b).
    intros. exploit me_bounded0; eauto. exploit Mem.alloc_result; eauto.
    unfold block in *; omega.
  econstructor; eauto.
(* vars *)
  intros. geninv (me_vars0 id); econstructor; eauto.
(* temps *)
  intros. exploit me_temps0; eauto. intros [v' [A B]]. 
  exists v'; split; auto. eapply val_inject_incr; eauto.
(* inv *)
  intros. rewrite OTHER in H. eauto. 
  red; intro; subst b0. rewrite H in TBOUND. omegaContradiction.
(* incr *)
  intros. eapply me_incr0; eauto. rewrite <- OTHER; eauto. 
  exploit Mem.alloc_result; eauto. unfold block in *; omega.
(* bounds *)
  intros. exploit Mem.perm_alloc_inv. eexact ALLOC. eauto. 
  rewrite zeq_false. eauto. 
  exploit me_bounded0; eauto.
Qed.

(** [match_env] and external calls *)

Remark inject_incr_separated_same:
  forall f1 f2 m1 m1',
  inject_incr f1 f2 -> inject_separated f1 f2 m1 m1' ->
  forall b, Mem.valid_block m1 b -> f2 b = f1 b.
Proof.
  intros. case_eq (f1 b).
  intros [b' delta] EQ. apply H; auto. 
  intros EQ. case_eq (f2 b).
  intros [b'1 delta1] EQ1. exploit H0; eauto. intros [C D]. contradiction.
  auto.
Qed.

Remark inject_incr_separated_same':
  forall f1 f2 m1 m1',
  inject_incr f1 f2 -> inject_separated f1 f2 m1 m1' ->
  forall b b' delta,
  f2 b = Some(b', delta) -> Mem.valid_block m1' b' -> f1 b = Some(b', delta).
Proof.
  intros. case_eq (f1 b).
  intros [b'1 delta1] EQ. exploit H; eauto. congruence.
  intros. exploit H0; eauto. intros [C D]. contradiction.
Qed.

Lemma match_env_external_call:
  forall f1 cenv e le m1 te sp lo hi m2 f2 m1',
  match_env f1 cenv e le m1 te sp lo hi ->
  mem_unchanged_on (loc_unmapped f1) m1 m2 ->
  inject_incr f1 f2 ->
  inject_separated f1 f2 m1 m1' ->
  (forall b ofs p, Mem.valid_block m1 b -> Mem.perm m2 b ofs Max p -> Mem.perm m1 b ofs Max p) ->
  hi <= Mem.nextblock m1 -> sp < Mem.nextblock m1' ->
  match_env f2 cenv e le m2 te sp lo hi.
Proof.
  intros until m1'. intros ME UNCHANGED INCR SEPARATED BOUNDS VALID VALID'.
  destruct UNCHANGED as [UNCHANGED1 UNCHANGED2].
  inversion ME. constructor; auto.
(* vars *)
  intros. geninv (me_vars0 id); econstructor; eauto.
(* temps *)
  intros. exploit me_temps0; eauto. intros [v' [A B]]. 
  exists v'; split; auto. eapply val_inject_incr; eauto.
(* inv *)
  intros. apply me_inv0 with delta. eapply inject_incr_separated_same'; eauto.
(* incr *)
  intros.
  exploit inject_incr_separated_same; eauto. 
  instantiate (1 := b). red; omega. intros. 
  apply me_incr0 with b delta. congruence. auto.
(* bounds *)
  intros. eapply me_bounds0; eauto. eapply BOUNDS; eauto. 
  red. exploit me_bounded0; eauto. omega.
Qed.
*)

(** * Invariant on abstract call stacks  *)

(** Call stacks represent abstractly the execution state of the current
  Csharpminor and Cminor functions, as well as the states of the
  calling functions.  A call stack is a list of frames, each frame
  collecting information on the current execution state of a Csharpminor
  function and its Cminor translation. *)

Inductive frame : Type :=
  Frame(cenv: compilenv)
       (tf: Cminor.function)
       (e: Csharpminor.env)
       (le: Csharpminor.temp_env)
       (te: Cminor.env)
       (sp: block)
       (lo hi: Z).

Definition callstack : Type := list frame.

(** Global environments match if the memory injection [f] leaves unchanged
  the references to global symbols and functions. *)

Inductive match_globalenvs (f: meminj) (bound: Z): Prop :=
  | mk_match_globalenvs
      (POS: bound > 0)
      (DOMAIN: forall b, b < bound -> f b = Some(b, 0))
      (IMAGE: forall b1 b2 delta, f b1 = Some(b2, delta) -> b2 < bound -> b1 = b2)
      (SYMBOLS: forall id b, Genv.find_symbol ge id = Some b -> b < bound)
      (FUNCTIONS: forall b fd, Genv.find_funct_ptr ge b = Some fd -> b < bound)
      (VARINFOS: forall b gv, Genv.find_var_info ge b = Some gv -> b < bound).

(** Matching of call stacks imply:
- matching of environments for each of the frames
- matching of the global environments
- separation conditions over the memory blocks allocated for C#minor local variables;
- separation conditions over the memory blocks allocated for Cminor stack data;
- freeable permissions on the parts of the Cminor stack data blocks
  that are not images of C#minor local variable blocks.
*)

Definition padding_freeable (f: meminj) (e: Csharpminor.env) (tm: mem) (sp: block) (sz: Z) : Prop :=
  forall ofs, 
  0 <= ofs < sz ->
  Mem.perm tm sp ofs Cur Freeable
  \/ exists id, exists b, exists sz, exists delta,
     e!id = Some(b, sz) /\ f b = Some(sp, delta) /\ delta <= ofs < delta + sz.

Inductive match_callstack (f: meminj) (m: mem) (tm: mem):
                          callstack -> Z -> Z -> Prop :=
  | mcs_nil:
      forall hi bound tbound,
      match_globalenvs f hi ->
      hi <= bound -> hi <= tbound ->
      match_callstack f m tm nil bound tbound 
  | mcs_cons:
      forall cenv tf e le te sp lo hi cs bound tbound
        (BOUND: hi <= bound)
        (TBOUND: sp < tbound)
        (MENV: match_env f cenv e le m te sp lo hi)
        (PERM: padding_freeable f e tm sp tf.(fn_stackspace))
        (MCS: match_callstack f m tm cs lo sp),
      match_callstack f m tm (Frame cenv tf e le te sp lo hi :: cs) bound tbound.

(** [match_callstack] implies [match_globalenvs]. *)

Lemma match_callstack_match_globalenvs:
  forall f m tm cs bound tbound,
  match_callstack f m tm cs bound tbound ->
  exists hi, match_globalenvs f hi.
Proof.
  induction 1; eauto.
Qed.

(** We now show invariance properties for [match_callstack] that
    generalize those for [match_env]. *)

Lemma padding_freeable_invariant:
  forall f1 m1 tm1 sp sz cenv e le te lo hi f2 tm2,
  padding_freeable f1 e tm1 sp sz ->
  match_env f1 cenv e le m1 te sp lo hi ->
  (forall ofs, Mem.perm tm1 sp ofs Cur Freeable -> Mem.perm tm2 sp ofs Cur Freeable) ->
  (forall b, b < hi -> f2 b = f1 b) ->
  padding_freeable f2 e tm2 sp sz.
Proof.
  intros; red; intros.
  exploit H; eauto. intros [A | [id [b [lv [delta [A [B C]]]]]]].
  left; auto. 
  exploit me_bounded; eauto. intros [D E].
  right; exists id; exists b; exists lv; exists delta; split.
  auto.
  rewrite H2; auto. 
Qed.

Lemma match_callstack_invariant:
  forall f1 m1 tm1 f2 m2 tm2 cs bound tbound,
  match_callstack f1 m1 tm1 cs bound tbound ->
  inject_incr f1 f2 ->
  (forall b ofs p, b < bound -> Mem.perm m2 b ofs Max p -> Mem.perm m1 b ofs Max p) ->
  (forall sp ofs, sp < tbound -> Mem.perm tm1 sp ofs Cur Freeable -> Mem.perm tm2 sp ofs Cur Freeable) ->
  (forall b, b < bound -> f2 b = f1 b) ->
  (forall b b' delta, f2 b = Some(b', delta) -> b' < tbound -> f1 b = Some(b', delta)) ->
  match_callstack f2 m2 tm2 cs bound tbound.
Proof.
  induction 1; intros.
  (* base case *)
  econstructor; eauto.
  inv H. constructor; intros; eauto.
  eapply IMAGE; eauto. eapply H6; eauto. omega.
  (* inductive case *)
  assert (lo <= hi) by eauto.
  econstructor; eauto.
  eapply match_env_invariant; eauto. 
    intros. eapply H1; eauto. omega.
    intros. apply H3. omega. 
  eapply padding_freeable_invariant; eauto. 
    intros. apply H3. omega. 
  eapply IHmatch_callstack; eauto. 
    intros. eapply H1; eauto. omega. 
    intros. eapply H2; eauto. omega. 
    intros. eapply H3; eauto. omega.
    intros. eapply H4; eauto. omega.
Qed.

Lemma match_callstack_set_temp:
  forall f cenv e le te sp lo hi cs bound tbound m tm tf id v tv,
  val_inject f v tv ->
  match_callstack f m tm (Frame cenv tf e le te sp lo hi :: cs) bound tbound ->
  match_callstack f m tm (Frame cenv tf e (PTree.set id v le) (PTree.set id tv te) sp lo hi :: cs) bound tbound.
Proof.
  intros. inv H0. constructor; auto.
  eapply match_env_set_temp; eauto. 
Qed.

Lemma match_callstack_incr_bound:
  forall f m tm cs bound tbound bound' tbound',
  match_callstack f m tm cs bound tbound ->
  bound <= bound' -> tbound <= tbound' ->
  match_callstack f m tm cs bound' tbound'.
Proof.
  intros. inv H.
  econstructor; eauto. omega. omega. 
  constructor; auto. omega. omega.
Qed.

(** Preservation of [match_callstack] by freeing all blocks allocated
  for local variables at function entry (on the Csharpminor side)
  and simultaneously freeing the Cminor stack data block. *)

Lemma in_blocks_of_env:
  forall e id b sz,
  e!id = Some(b, sz) -> In (b, 0, sz) (blocks_of_env e).
Proof.
  unfold blocks_of_env; intros. 
  change (b, 0, sz) with (block_of_binding (id, (b, sz))).
  apply List.in_map. apply PTree.elements_correct. auto.
Qed.

Lemma in_blocks_of_env_inv:
  forall b lo hi e,
  In (b, lo, hi) (blocks_of_env e) ->
  exists id, e!id = Some(b, hi) /\ lo = 0.
Proof.
  unfold blocks_of_env; intros. 
  exploit list_in_map_inv; eauto. intros [[id [b' sz]] [A B]].
  unfold block_of_binding in A. inv A. 
  exists id; intuition. apply PTree.elements_complete. auto.
Qed.

Lemma match_callstack_freelist:
  forall f cenv tf e le te sp lo hi cs m m' tm,
  Mem.inject f m tm ->
  Mem.free_list m (blocks_of_env e) = Some m' ->
  match_callstack f m tm (Frame cenv tf e le te sp lo hi :: cs) (Mem.nextblock m) (Mem.nextblock tm) ->
  exists tm',
  Mem.free tm sp 0 tf.(fn_stackspace) = Some tm'
  /\ match_callstack f m' tm' cs (Mem.nextblock m') (Mem.nextblock tm')
  /\ Mem.inject f m' tm'.
Proof.
  intros until tm; intros INJ FREELIST MCS. inv MCS. inv MENV.
  assert ({tm' | Mem.free tm sp 0 (fn_stackspace tf) = Some tm'}).
  apply Mem.range_perm_free.
  red; intros.
  exploit PERM; eauto. intros [A | [id [b [sz [delta [A [B C]]]]]]]. 
  auto.
  assert (Mem.range_perm m b 0 sz Cur Freeable). 
  eapply free_list_freeable; eauto. eapply in_blocks_of_env; eauto.
  replace ofs with ((ofs - delta) + delta) by omega. 
  eapply Mem.perm_inject; eauto. apply H0. omega. 
  destruct X as  [tm' FREE].
  exploit nextblock_freelist; eauto. intro NEXT.
  exploit Mem.nextblock_free; eauto. intro NEXT'.
  exists tm'. split. auto. split.
  rewrite NEXT; rewrite NEXT'.
  apply match_callstack_incr_bound with lo sp; try omega.
  apply match_callstack_invariant with f m tm; auto.
  intros. eapply perm_freelist; eauto.
  intros. eapply Mem.perm_free_1; eauto. left; unfold block; omega.
  eapply Mem.free_inject; eauto.
  intros. exploit me_inv0; eauto. intros [id [sz A]]. 
  exists 0; exists sz; split.
  eapply in_blocks_of_env; eauto.
  eapply me_bounds0; eauto. eapply Mem.perm_max. eauto. 
Qed.

(** Preservation of [match_callstack] by allocations. *)

Lemma match_callstack_alloc_left:
  forall f1 m1 tm cenv tf e le te sp lo cs sz m2 b f2 ofs id,
  match_callstack f1 m1 tm
    (Frame cenv tf e le te sp lo (Mem.nextblock m1) :: cs)
    (Mem.nextblock m1) (Mem.nextblock tm) ->
  Mem.alloc m1 0 sz = (m2, b) ->
  inject_incr f1 f2 ->
  f2 b = Some(sp, ofs) ->
  (forall b', b' <> b -> f2 b' = f1 b') ->
  e!id = None ->
  match_callstack f2 m2 tm
    (Frame (PTree.set id ofs cenv) tf (PTree.set id (b, sz) e) le te sp lo (Mem.nextblock m2) :: cs)
    (Mem.nextblock m2) (Mem.nextblock tm).
Proof.
  intros until id; intros MCS ALLOC INCR SAME OTHER ENV.
  inv MCS. 
  exploit Mem.alloc_result; eauto. intro RESULT.
  exploit Mem.nextblock_alloc; eauto. intro NEXT.
  constructor.
  omega. auto. 
  eapply match_env_alloc_same; eauto.
  red; intros. exploit PERM; eauto. intros [A | [id' [b' [sz' [delta' [A [B C]]]]]]].
  left; auto.
  right; exists id'; exists b'; exists sz'; exists delta'.
  split. rewrite PTree.gso; auto. congruence. 
  split. apply INCR; auto. auto.
  assert (lo <= Mem.nextblock m1) by eauto.
  eapply match_callstack_invariant; eauto.
  intros. eapply Mem.perm_alloc_4; eauto. unfold block in *; omega.
  intros. apply OTHER. unfold block in *; omega.
  intros. destruct (zeq b0 b).
    subst b0. rewrite SAME in H0; inv H0. omegaContradiction.
    rewrite OTHER in H0; auto.
Qed.

Lemma match_callstack_alloc_right:
  forall f le m tm cs tf sp tm' te,
  match_callstack f m tm cs (Mem.nextblock m) (Mem.nextblock tm) ->
  Mem.alloc tm 0 tf.(fn_stackspace) = (tm', sp) ->
  Mem.inject f m tm ->
  (forall id v, le!id = Some v -> exists v', te!(id) = Some v' /\ val_inject f v v') ->
  match_callstack f m tm'
    (Frame (PTree.empty Z) tf empty_env le te sp (Mem.nextblock m) (Mem.nextblock m) :: cs)
    (Mem.nextblock m) (Mem.nextblock tm').
Proof.
  intros.
  exploit Mem.alloc_result; eauto. intro RES.
  exploit Mem.nextblock_alloc; eauto. intro NEXT.
  constructor. omega. unfold block in *; omega.
(* match env *) 
  constructor.
(* vars *)
  intros. repeat rewrite PTree.gempty. constructor.
(* temps *)
  assumption.
(* low high *)
  omega.
(* bounded *)
  intros. rewrite PTree.gempty in H3. congruence.
(* inv *)
  intros. 
  assert (sp <> sp). apply Mem.valid_not_valid_diff with tm.
  eapply Mem.valid_block_inject_2; eauto. eauto with mem. 
  tauto.
(* incr *)
  intros. rewrite RES. change (Mem.valid_block tm tb).
  eapply Mem.valid_block_inject_2; eauto.
(* bounds *)
  unfold empty_env; intros. rewrite PTree.gempty in H3. congruence.
(* padding freeable *)
  red; intros. left. eapply Mem.perm_alloc_2; eauto. 
(* previous call stack *)
  rewrite RES. apply match_callstack_invariant with f m tm; auto.
  intros. eapply Mem.perm_alloc_1; eauto. 
Qed.

(** Decidability of the predicate "this is not a padding location" *)

Definition is_reachable (f: meminj) (e: Csharpminor.env) (sp: block) (ofs: Z) : Prop :=
  exists id, exists b, exists sz, exists delta,
  e!id = Some(b, sz) /\ f b = Some(sp, delta) /\ delta <= ofs < delta + sz.

Lemma is_reachable_dec:
  forall f e sp ofs, is_reachable f e sp ofs \/ ~is_reachable f e sp ofs.
Proof.
  intros. 
  set (pred := fun id_b_sz : ident * (block * Z) =>
                 match id_b_sz with
                 | (id, (b, sz)) =>
                      match f b with
                           | None => false
                           | Some(sp', delta) =>
                               if eq_block sp sp'
                               then zle delta ofs && zlt ofs (delta + sz)
                               else false
                      end
                 end).
  destruct (List.existsb pred (PTree.elements e)) as []_eqn.
  rewrite List.existsb_exists in Heqb. 
  destruct Heqb as [[id [b sz]] [A B]].
  simpl in B. destruct (f b) as [[sp' delta] |]_eqn; try discriminate.
  destruct (eq_block sp sp'); try discriminate.
  destruct (andb_prop _ _ B). 
  left; red. exists id; exists b; exists sz; exists delta.
  split. apply PTree.elements_complete; auto. 
  split. congruence.
  split; eapply proj_sumbool_true; eauto.
  right; red. intros [id [b [sz [delta [A [B C]]]]]].
  assert (existsb pred (PTree.elements e) = true).
  rewrite List.existsb_exists. exists (id, (b, sz)); split.
  apply PTree.elements_correct; auto. 
  simpl. rewrite B. rewrite dec_eq_true.
  unfold proj_sumbool. destruct C. rewrite zle_true; auto. rewrite zlt_true; auto. 
  congruence.
Qed.

(** Preservation of [match_callstack] by external calls. *)

Lemma match_callstack_external_call:
  forall f1 f2 m1 m2 m1' m2',
  mem_unchanged_on (loc_unmapped f1) m1 m2 ->
  mem_unchanged_on (loc_out_of_reach f1 m1) m1' m2' ->
  inject_incr f1 f2 ->
  inject_separated f1 f2 m1 m1' ->
  (forall b ofs p, Mem.valid_block m1 b -> Mem.perm m2 b ofs Max p -> Mem.perm m1 b ofs Max p) ->
  forall cs bound tbound,
  match_callstack f1 m1 m1' cs bound tbound ->
  bound <= Mem.nextblock m1 -> tbound <= Mem.nextblock m1' ->
  match_callstack f2 m2 m2' cs bound tbound.
Proof.
  intros until m2'. 
  intros UNMAPPED OUTOFREACH INCR SEPARATED MAXPERMS.
  destruct OUTOFREACH as [OUTOFREACH1 OUTOFREACH2].
  induction 1; intros.
(* base case *)
  apply mcs_nil with hi; auto.
  inv H. constructor; auto.
  intros. case_eq (f1 b1). 
  intros [b2' delta'] EQ. rewrite (INCR _ _ _ EQ) in H. inv H. eauto. 
  intro EQ. exploit SEPARATED; eauto. intros [A B]. elim B. red. omega. 
(* inductive case *)
  constructor. auto. auto. 
  eapply match_env_invariant; eauto. 
  intros. apply MAXPERMS; auto. red; omega.
  red in SEPARATED. intros. destruct (f1 b) as [[b' delta']|]_eqn. 
  exploit INCR; eauto. congruence.
  exploit SEPARATED; eauto. intros [A B]. elim B. red. omega. 
  intros. assert (lo <= hi) by eauto. destruct (f1 b) as [[b' delta']|]_eqn. 
  apply INCR; auto. 
  destruct (f2 b) as [[b' delta']|]_eqn; auto.
  exploit SEPARATED; eauto. intros [A B]. elim A. red. omega. 
  (* padding-freeable *)
  red; intros.
  destruct (is_reachable_dec f1 e sp ofs).
  destruct H3 as [id [b [sz [delta [A [B C]]]]]].
  right; exists id; exists b; exists sz; exists delta.
  split. auto. split. apply INCR; auto. auto.
  exploit PERM; eauto. intros [A|A]; try contradiction. left.
  apply OUTOFREACH1; auto. red; intros.
  red; intros; elim H3.
  exploit me_inv; eauto. intros [id [lv B]].
  exploit me_bounds; eauto. intros C.
  red. exists id; exists b0; exists lv; exists delta. intuition omega. 
  (* induction *)
  eapply IHmatch_callstack; eauto. inv MENV; omega. omega.
Qed.

Remark inj_preserves_globals:
  forall f hi,
  match_globalenvs f hi ->
  meminj_preserves_globals ge f.
Proof.
  intros. inv H.
  split. intros. apply DOMAIN. eapply SYMBOLS. eauto.
  split. intros. apply DOMAIN. eapply VARINFOS. eauto. 
  intros. symmetry. eapply IMAGE; eauto. 
Qed.

(** * Properties of compile-time approximations of values *)

Definition val_match_approx (a: approx) (v: val) : Prop :=
  match a with
  | Int1 => v = Val.zero_ext 1 v
  | Int7 => v = Val.zero_ext 8 v /\ v = Val.sign_ext 8 v
  | Int8u => v = Val.zero_ext 8 v
  | Int8s => v = Val.sign_ext 8 v
  | Int15 => v = Val.zero_ext 16 v /\ v = Val.sign_ext 16 v
  | Int16u => v = Val.zero_ext 16 v
  | Int16s => v = Val.sign_ext 16 v
  | Float32 => v = Val.singleoffloat v
  | Any => True
  end.

Remark undef_match_approx: forall a, val_match_approx a Vundef.
Proof.
  destruct a; simpl; auto.
Qed.

Lemma val_match_approx_increasing:
  forall a1 a2 v,
  Approx.bge a1 a2 = true -> val_match_approx a2 v -> val_match_approx a1 v.
Proof.
  assert (A: forall v, v = Val.zero_ext 8 v -> v = Val.zero_ext 16 v).
    intros. rewrite H.
    destruct v; simpl; auto. decEq. symmetry. 
    apply Int.zero_ext_widen. compute; auto. split. omega. compute; auto.
  assert (B: forall v, v = Val.sign_ext 8 v -> v = Val.sign_ext 16 v).
    intros. rewrite H.
    destruct v; simpl; auto. decEq. symmetry. 
    apply Int.sign_ext_widen. compute; auto. split. omega. compute; auto.
  assert (C: forall v, v = Val.zero_ext 8 v -> v = Val.sign_ext 16 v).
    intros. rewrite H.
    destruct v; simpl; auto. decEq. symmetry. 
    apply Int.sign_zero_ext_widen. compute; auto. split. omega. compute; auto.
  assert (D: forall v, v = Val.zero_ext 1 v -> v = Val.zero_ext 8 v).
    intros. rewrite H.
    destruct v; simpl; auto. decEq. symmetry. 
    apply Int.zero_ext_widen. compute; auto. split. omega. compute; auto.
  assert (E: forall v, v = Val.zero_ext 1 v -> v = Val.sign_ext 8 v).
    intros. rewrite H.
    destruct v; simpl; auto. decEq. symmetry. 
    apply Int.sign_zero_ext_widen. compute; auto. split. omega. compute; auto.
  intros. 
  unfold Approx.bge in H; destruct a1; try discriminate; destruct a2; simpl in *; try discriminate; intuition.
Qed.

Lemma approx_of_int_sound:
  forall n, val_match_approx (Approx.of_int n) (Vint n).
Proof.
  unfold Approx.of_int; intros.
  destruct (Int.eq_dec n Int.zero); simpl. subst; auto. 
  destruct (Int.eq_dec n Int.one); simpl. subst; auto. 
  destruct (Int.eq_dec n (Int.zero_ext 7 n)). simpl.
    split.
    decEq. rewrite e. symmetry. apply Int.zero_ext_widen. compute; auto. split. omega. compute; auto.
    decEq. rewrite e. symmetry. apply Int.sign_zero_ext_widen. compute; auto. compute; auto. 
  destruct (Int.eq_dec n (Int.zero_ext 8 n)). simpl; congruence.
  destruct (Int.eq_dec n (Int.sign_ext 8 n)). simpl; congruence.
  destruct (Int.eq_dec n (Int.zero_ext 15 n)). simpl.
    split.
    decEq. rewrite e. symmetry. apply Int.zero_ext_widen. compute; auto. split. omega. compute; auto.
    decEq. rewrite e. symmetry. apply Int.sign_zero_ext_widen. compute; auto. compute; auto. 
  destruct (Int.eq_dec n (Int.zero_ext 16 n)). simpl; congruence.
  destruct (Int.eq_dec n (Int.sign_ext 16 n)). simpl; congruence.
  exact I.
Qed.

Lemma approx_of_float_sound:
  forall f, val_match_approx (Approx.of_float f) (Vfloat f).
Proof.
  unfold Approx.of_float; intros. 
  destruct (Float.eq_dec f (Float.singleoffloat f)); simpl; auto. congruence.
Qed.

Lemma approx_of_chunk_sound:
  forall chunk m b ofs v,
  Mem.load chunk m b ofs = Some v ->
  val_match_approx (Approx.of_chunk chunk) v.
Proof.
  intros. exploit Mem.load_cast; eauto. 
  destruct chunk; intros; simpl; auto.
Qed.

Lemma approx_of_unop_sound:
  forall op v1 v a1,
  eval_unop op v1 = Some v ->
  val_match_approx a1 v1 ->
  val_match_approx (Approx.unop op a1) v.
Proof.
  destruct op; simpl; intros; auto; inv H.
  destruct v1; simpl; auto. rewrite Int.zero_ext_idem; auto. compute; auto.
  destruct v1; simpl; auto. rewrite Int.sign_ext_idem; auto. compute; auto.
  destruct v1; simpl; auto. rewrite Int.zero_ext_idem; auto. compute; auto.
  destruct v1; simpl; auto. rewrite Int.sign_ext_idem; auto. compute; auto.
  destruct v1; simpl; auto. rewrite Float.singleoffloat_idem; auto.
Qed.

Lemma approx_bitwise_and_sound:
  forall a1 v1 a2 v2,
  val_match_approx a1 v1 -> val_match_approx a2 v2 ->
  val_match_approx (Approx.bitwise_and a1 a2) (Val.and v1 v2).
Proof.
  assert (X: forall v1 v2 N, 0 < N < Z_of_nat Int.wordsize ->
            v2 = Val.zero_ext N v2 ->
            Val.and v1 v2 = Val.zero_ext N (Val.and v1 v2)).
    intros. rewrite Val.zero_ext_and in *; auto. 
    rewrite Val.and_assoc. congruence. 
  assert (Y: forall v1 v2 N, 0 < N < Z_of_nat Int.wordsize ->
            v1 = Val.zero_ext N v1 ->
            Val.and v1 v2 = Val.zero_ext N (Val.and v1 v2)).
    intros. rewrite (Val.and_commut v1 v2). apply X; auto.
  assert (P: forall a v, val_match_approx a v -> Approx.bge Int8u a = true ->
               v = Val.zero_ext 8 v).
    intros. apply (val_match_approx_increasing Int8u a v); auto.
  assert (Q: forall a v, val_match_approx a v -> Approx.bge Int16u a = true ->
               v = Val.zero_ext 16 v).
    intros. apply (val_match_approx_increasing Int16u a v); auto.
  assert (R: forall a v, val_match_approx a v -> Approx.bge Int1 a = true ->
               v = Val.zero_ext 1 v).
    intros. apply (val_match_approx_increasing Int1 a v); auto.

  intros; unfold Approx.bitwise_and. 
  destruct (Approx.bge Int1 a1) as []_eqn. simpl. apply Y; eauto. compute; auto.
  destruct (Approx.bge Int1 a2) as []_eqn. simpl. apply X; eauto. compute; auto.
  destruct (Approx.bge Int8u a1) as []_eqn. simpl. apply Y; eauto. compute; auto.
  destruct (Approx.bge Int8u a2) as []_eqn. simpl. apply X; eauto. compute; auto.
  destruct (Approx.bge Int16u a1) as []_eqn. simpl. apply Y; eauto. compute; auto.
  destruct (Approx.bge Int16u a2) as []_eqn. simpl. apply X; eauto. compute; auto.
  simpl; auto. 
Qed.

Lemma approx_bitwise_or_sound:
  forall (sem_op: val -> val -> val) a1 v1 a2 v2,
  (forall a b c, sem_op (Val.and a (Vint c)) (Val.and b (Vint c)) =
                 Val.and (sem_op a b) (Vint c)) ->
  val_match_approx a1 v1 -> val_match_approx a2 v2 ->
  val_match_approx (Approx.bitwise_or a1 a2) (sem_op v1 v2).
Proof.
  intros.
  assert (X: forall v v' N, 0 < N < Z_of_nat Int.wordsize ->
            v = Val.zero_ext N v ->
            v' = Val.zero_ext N v' ->
            sem_op v v' = Val.zero_ext N (sem_op v v')).
    intros. rewrite Val.zero_ext_and in *; auto.
    rewrite H3; rewrite H4. rewrite H. rewrite Val.and_assoc.
    simpl. rewrite Int.and_idem. auto.

  unfold Approx.bitwise_or. 

  destruct (Approx.bge Int1 a1 && Approx.bge Int1 a2) as []_eqn.
  destruct (andb_prop _ _ Heqb).
  simpl. apply X. compute; auto. 
  apply (val_match_approx_increasing Int1 a1 v1); auto.
  apply (val_match_approx_increasing Int1 a2 v2); auto.

  destruct (Approx.bge Int8u a1 && Approx.bge Int8u a2) as []_eqn.
  destruct (andb_prop _ _ Heqb0).
  simpl. apply X. compute; auto. 
  apply (val_match_approx_increasing Int8u a1 v1); auto.
  apply (val_match_approx_increasing Int8u a2 v2); auto.

  destruct (Approx.bge Int16u a1 && Approx.bge Int16u a2) as []_eqn.
  destruct (andb_prop _ _ Heqb1).
  simpl. apply X. compute; auto. 
  apply (val_match_approx_increasing Int16u a1 v1); auto.
  apply (val_match_approx_increasing Int16u a2 v2); auto.

  exact I.
Qed.

Lemma approx_of_binop_sound:
  forall op v1 a1 v2 a2 m v,
  eval_binop op v1 v2 m = Some v ->
  val_match_approx a1 v1 -> val_match_approx a2 v2 ->
  val_match_approx (Approx.binop op a1 a2) v.
Proof.
  assert (OB: forall ob, val_match_approx Int1 (Val.of_optbool ob)).
    destruct ob; simpl. destruct b; auto. auto.
  
  destruct op; intros; simpl Approx.binop; simpl in H; try (exact I); inv H.
  apply approx_bitwise_and_sound; auto.
  apply approx_bitwise_or_sound; auto.
    intros. destruct a; destruct b; simpl; auto.
    rewrite (Int.and_commut i c); rewrite (Int.and_commut i0 c). 
    rewrite <- Int.and_or_distrib. rewrite Int.and_commut. auto.
  apply approx_bitwise_or_sound; auto.
    intros. destruct a; destruct b; simpl; auto.
    rewrite (Int.and_commut i c); rewrite (Int.and_commut i0 c). 
    rewrite <- Int.and_xor_distrib. rewrite Int.and_commut. auto.
  apply OB.
  apply OB.
  apply OB.
Qed.

Lemma approx_unop_is_redundant_sound:
  forall op a v,
  Approx.unop_is_redundant op a = true ->
  val_match_approx a v ->
  eval_unop op v = Some v.
Proof.
  unfold Approx.unop_is_redundant; intros; destruct op; try discriminate.
(* cast8unsigned *)
  assert (V: val_match_approx Int8u v) by (eapply val_match_approx_increasing; eauto).
  simpl in *. congruence.
(* cast8signed *)
  assert (V: val_match_approx Int8s v) by (eapply val_match_approx_increasing; eauto).
  simpl in *. congruence.
(* cast16unsigned *)
  assert (V: val_match_approx Int16u v) by (eapply val_match_approx_increasing; eauto).
  simpl in *. congruence.
(* cast16signed *)
  assert (V: val_match_approx Int16s v) by (eapply val_match_approx_increasing; eauto).
  simpl in *. congruence.
(* singleoffloat *)
  assert (V: val_match_approx Float32 v) by (eapply val_match_approx_increasing; eauto).
  simpl in *. congruence.
Qed.

(** * Compatibility of evaluation functions with respect to memory injections. *)

Remark val_inject_val_of_bool:
  forall f b, val_inject f (Val.of_bool b) (Val.of_bool b).
Proof.
  intros; destruct b; constructor.
Qed.

Remark val_inject_val_of_optbool:
  forall f ob, val_inject f (Val.of_optbool ob) (Val.of_optbool ob).
Proof.
  intros; destruct ob; simpl. destruct b; constructor. constructor.
Qed.

Ltac TrivialExists :=
  match goal with
  | [ |- exists y, Some ?x = Some y /\ val_inject _ _ _ ] =>
      exists x; split; [auto | try(econstructor; eauto)]
  | [ |- exists y, _ /\ val_inject _ (Vint ?x) _ ] =>
      exists (Vint x); split; [eauto with evalexpr | constructor]
  | [ |- exists y, _ /\ val_inject _ (Vfloat ?x) _ ] =>
      exists (Vfloat x); split; [eauto with evalexpr | constructor]
  | _ => idtac
  end.

(** Compatibility of [eval_unop] with respect to [val_inject]. *)

Lemma eval_unop_compat:
  forall f op v1 tv1 v,
  eval_unop op v1 = Some v ->
  val_inject f v1 tv1 ->
  exists tv,
     eval_unop op tv1 = Some tv
  /\ val_inject f v tv.
Proof.
  destruct op; simpl; intros.
  inv H; inv H0; simpl; TrivialExists.
  inv H; inv H0; simpl; TrivialExists.
  inv H; inv H0; simpl; TrivialExists.
  inv H; inv H0; simpl; TrivialExists.
  inv H; inv H0; simpl; TrivialExists.
  inv H; inv H0; simpl; TrivialExists.
  inv H; inv H0; simpl; TrivialExists.
  inv H; inv H0; simpl; TrivialExists.
  inv H; inv H0; simpl; TrivialExists.
  inv H0; simpl in H; inv H. simpl. destruct (Float.intoffloat f0); simpl in *; inv H1. TrivialExists.
  inv H0; simpl in H; inv H. simpl. destruct (Float.intuoffloat f0); simpl in *; inv H1. TrivialExists.
  inv H0; simpl in H; inv H. simpl. TrivialExists.
  inv H0; simpl in H; inv H. simpl. TrivialExists.
Qed.

(** Compatibility of [eval_binop] with respect to [val_inject]. *)

Lemma eval_binop_compat:
  forall f op v1 tv1 v2 tv2 v m tm,
  eval_binop op v1 v2 m = Some v ->
  val_inject f v1 tv1 ->
  val_inject f v2 tv2 ->
  Mem.inject f m tm ->
  exists tv,
     eval_binop op tv1 tv2 tm = Some tv
  /\ val_inject f v tv.
Proof.
  destruct op; simpl; intros.
  inv H; inv H0; inv H1; TrivialExists.
    repeat rewrite Int.add_assoc. decEq. apply Int.add_commut.
    repeat rewrite Int.add_assoc. decEq. apply Int.add_commut.
  inv H; inv H0; inv H1; TrivialExists.
    apply Int.sub_add_l.
    simpl. destruct (zeq b1 b0); auto.
    subst b1. rewrite H in H0; inv H0. 
    rewrite zeq_true. rewrite Int.sub_shifted. auto.
  inv H; inv H0; inv H1; TrivialExists.
  inv H0; try discriminate; inv H1; try discriminate. simpl in *. 
    destruct (Int.eq i0 Int.zero
      || Int.eq i (Int.repr Int.min_signed) && Int.eq i0 Int.mone); inv H; TrivialExists.
  inv H0; try discriminate; inv H1; try discriminate. simpl in *. 
    destruct (Int.eq i0 Int.zero); inv H. TrivialExists.
  inv H0; try discriminate; inv H1; try discriminate. simpl in *. 
    destruct (Int.eq i0 Int.zero
      || Int.eq i (Int.repr Int.min_signed) && Int.eq i0 Int.mone); inv H; TrivialExists.
  inv H0; try discriminate; inv H1; try discriminate. simpl in *. 
    destruct (Int.eq i0 Int.zero); inv H. TrivialExists.
  inv H; inv H0; inv H1; TrivialExists.
  inv H; inv H0; inv H1; TrivialExists.
  inv H; inv H0; inv H1; TrivialExists.
  inv H; inv H0; inv H1; TrivialExists. simpl. destruct (Int.ltu i0 Int.iwordsize); auto.
  inv H; inv H0; inv H1; TrivialExists. simpl. destruct (Int.ltu i0 Int.iwordsize); auto.
  inv H; inv H0; inv H1; TrivialExists. simpl. destruct (Int.ltu i0 Int.iwordsize); auto.
  inv H; inv H0; inv H1; TrivialExists.
  inv H; inv H0; inv H1; TrivialExists.
  inv H; inv H0; inv H1; TrivialExists.
  inv H; inv H0; inv H1; TrivialExists.
  inv H; inv H0; inv H1; TrivialExists. apply val_inject_val_of_optbool.
(* cmpu *)
  inv H; inv H0; inv H1; TrivialExists.
    apply val_inject_val_of_optbool.
    apply val_inject_val_of_optbool.
    apply val_inject_val_of_optbool.
Opaque Int.add.
    unfold Val.cmpu. simpl. 
    destruct (Mem.valid_pointer m b1 (Int.unsigned ofs1)) as []_eqn; simpl; auto.
    destruct (Mem.valid_pointer m b0 (Int.unsigned ofs0)) as []_eqn; simpl; auto.
    exploit Mem.valid_pointer_inject_val. eauto. eexact Heqb. econstructor; eauto. 
    intros V1. rewrite V1.
    exploit Mem.valid_pointer_inject_val. eauto. eexact Heqb0. econstructor; eauto. 
    intros V2. rewrite V2. simpl.
    destruct (zeq b1 b0).
    (* same blocks *)
    subst b1. rewrite H in H0; inv H0. rewrite zeq_true. 
    rewrite Int.translate_cmpu. apply val_inject_val_of_optbool.
    eapply Mem.valid_pointer_inject_no_overflow; eauto.
    eapply Mem.valid_pointer_inject_no_overflow; eauto.
    (* different source blocks *)
    destruct (zeq b2 b3).
    exploit Mem.different_pointers_inject; eauto. intros [A|A]. 
    congruence.
    destruct c; simpl; auto. 
    rewrite Int.eq_false. constructor. congruence.
    rewrite Int.eq_false. constructor. congruence.
    apply val_inject_val_of_optbool.
  (* cmpf *)
  inv H; inv H0; inv H1; TrivialExists. apply val_inject_val_of_optbool.
Qed.

(** * Correctness of Cminor construction functions *)

Lemma make_stackaddr_correct:
  forall sp te tm ofs,
  eval_expr tge (Vptr sp Int.zero) te tm
            (make_stackaddr ofs) (Vptr sp (Int.repr ofs)).
Proof.
  intros; unfold make_stackaddr.
  eapply eval_Econst. simpl. decEq. decEq.
  rewrite Int.add_commut. apply Int.add_zero.
Qed.

Lemma make_globaladdr_correct:
  forall sp te tm id b,
  Genv.find_symbol tge id = Some b ->
  eval_expr tge (Vptr sp Int.zero) te tm
            (make_globaladdr id) (Vptr b Int.zero).
Proof.
  intros; unfold make_globaladdr.
  eapply eval_Econst. simpl. rewrite H. auto.
Qed.

(** Correctness of [make_store]. *)

Inductive val_lessdef_upto (m: int): val -> val -> Prop :=
  | val_lessdef_upto_base:
      forall v1 v2, Val.lessdef v1 v2 -> val_lessdef_upto m v1 v2
  | val_lessdef_upto_int:
      forall n1 n2, Int.and n1 m = Int.and n2 m -> val_lessdef_upto m (Vint n1) (Vint n2).

Hint Resolve val_lessdef_upto_base.

Remark val_lessdef_upto_and:
  forall m v1 v2 p,
  val_lessdef_upto m v1 v2 -> Int.and p m = m ->
  val_lessdef_upto m (Val.and v1 (Vint p)) v2.
Proof.
  intros. inversion H; clear H.
  inversion H1. destruct v2; simpl; auto. 
  apply val_lessdef_upto_int. rewrite Int.and_assoc. congruence.
  simpl. auto. 
  simpl. apply val_lessdef_upto_int. rewrite Int.and_assoc. congruence. 
Qed.

Remark val_lessdef_upto_zero_ext:
  forall m v1 v2 p,
  val_lessdef_upto m v1 v2 -> Int.and (Int.repr (two_p p - 1)) m = m -> 0 < p < 32 ->
  val_lessdef_upto m (Val.zero_ext p v1) v2.
Proof.
  intros. inversion H; clear H.
  inversion H2. destruct v2; simpl; auto.
  apply val_lessdef_upto_int. rewrite Int.zero_ext_and; auto. 
  rewrite Int.and_assoc. rewrite H0. auto. 
  simpl; auto.
  simpl. apply val_lessdef_upto_int. rewrite Int.zero_ext_and; auto.
  rewrite Int.and_assoc. rewrite H0. auto.
Qed.

Remark val_lessdef_upto_sign_ext:
  forall m v1 v2 p,
  val_lessdef_upto m v1 v2 -> Int.and (Int.repr (two_p p - 1)) m = m -> 0 < p < 32 ->
  val_lessdef_upto m (Val.sign_ext p v1) v2.
Proof.
  intros.
  assert (A: forall x, Int.and (Int.sign_ext p x) m = Int.and x m).
    intros. transitivity (Int.and (Int.zero_ext p (Int.sign_ext p x)) m).
    rewrite Int.zero_ext_and; auto. rewrite Int.and_assoc. congruence.
    rewrite Int.zero_ext_sign_ext.
    rewrite Int.zero_ext_and; auto. rewrite Int.and_assoc. congruence.
  inversion H; clear H.
  inversion H2. destruct v2; simpl; auto.
  apply val_lessdef_upto_int. auto. 
  simpl; auto.
  simpl. apply val_lessdef_upto_int. rewrite A. auto. 
Qed.

Remark val_lessdef_upto_shru:
  forall m v1 v2 p,
  val_lessdef_upto (Int.shl m p) v1 v2 -> Int.shru (Int.shl m p) p = m ->
  val_lessdef_upto m (Val.shru v1 (Vint p)) (Val.shru v2 (Vint p)).
Proof.
  intros. inversion H; clear H.
  inversion H1; simpl; auto.
  simpl. destruct (Int.ltu p Int.iwordsize); auto. apply val_lessdef_upto_int.
  rewrite <- H0. repeat rewrite Int.and_shru. congruence.
Qed.

Remark val_lessdef_upto_shr:
  forall m v1 v2 p,
  val_lessdef_upto (Int.shl m p) v1 v2 -> Int.shru (Int.shl m p) p = m ->
  val_lessdef_upto m (Val.shr v1 (Vint p)) (Val.shr v2 (Vint p)).
Proof.
  intros. inversion H; clear H.
  inversion H1; simpl; auto.
  simpl. destruct (Int.ltu p Int.iwordsize); auto. apply val_lessdef_upto_int.
  repeat rewrite Int.shr_and_shru_and; auto.
  rewrite <- H0. repeat rewrite Int.and_shru. congruence.
Qed.

Lemma eval_uncast_int:
  forall m sp te tm a x,
  eval_expr tge sp te tm a x ->
  exists v, eval_expr tge sp te tm (uncast_int m a) v /\ val_lessdef_upto m x v.
Proof.
  assert (EQ: forall p q, Int.eq p q = true -> p = q).
    intros. generalize (Int.eq_spec p q). rewrite H; auto.   
  intros until a. functional induction (uncast_int m a); intros.
  (* cast8unsigned *)
  inv H. simpl in H4; inv H4. exploit IHe; eauto. intros [v [A B]].
  exists v; split; auto. apply val_lessdef_upto_zero_ext; auto. 
  compute; auto.
  exists x; auto. 
  (* cast8signed *)
  inv H. simpl in H4; inv H4. exploit IHe; eauto. intros [v [A B]].
  exists v; split; auto. apply val_lessdef_upto_sign_ext; auto. 
  compute; auto.
  exists x; auto. 
  (* cast16unsigned *)
  inv H. simpl in H4; inv H4. exploit IHe; eauto. intros [v [A B]].
  exists v; split; auto. apply val_lessdef_upto_zero_ext; auto. 
  compute; auto.
  exists x; auto. 
  (* cast16signed *)
  inv H. simpl in H4; inv H4. exploit IHe; eauto. intros [v [A B]].
  exists v; split; auto. apply val_lessdef_upto_sign_ext; auto. 
  compute; auto.
  exists x; auto. 
  (* and *)
  inv H. simpl in H6; inv H6. inv H5. simpl in H0. inv H0.
  exploit IHe; eauto. intros [v [A B]].
  exists v; split; auto. apply val_lessdef_upto_and; auto.
  exists x; auto.
  (* shru *)
  inv H. simpl in H6; inv H6. inv H5. simpl in H0. inv H0.
  exploit IHe; eauto. intros [v [A B]].
  exists (Val.shru v (Vint n)); split.
  econstructor. eauto. econstructor. simpl; reflexivity. auto. 
  apply val_lessdef_upto_shru; auto.
  exists x; auto.
  (* shr *)
  inv H. simpl in H6; inv H6. inv H5. simpl in H0. inv H0.
  exploit IHe; eauto. intros [v [A B]].
  exists (Val.shr v (Vint n)); split.
  econstructor. eauto. econstructor. simpl; reflexivity. auto. 
  apply val_lessdef_upto_shr; auto.
  exists x; auto.
  (* default *)
  exists x; split; auto.
Qed.

Inductive val_lessdef_upto_single: val -> val -> Prop :=
  | val_lessdef_upto_single_base:
      forall v1 v2, Val.lessdef v1 v2 -> val_lessdef_upto_single v1 v2
  | val_lessdef_upto_single_float:
      forall n1 n2, Float.singleoffloat n1 = Float.singleoffloat n2 -> val_lessdef_upto_single (Vfloat n1) (Vfloat n2).

Hint Resolve val_lessdef_upto_single_base.

Lemma eval_uncast_float32:
  forall sp te tm a x,
  eval_expr tge sp te tm a x ->
  exists v, eval_expr tge sp te tm (uncast_float32 a) v /\ val_lessdef_upto_single x v.
Proof.
  intros until a. functional induction (uncast_float32 a); intros.
  (* singleoffloat *)
  inv H. simpl in H4; inv H4. exploit IHe; eauto. intros [v [A B]].
  exists v; split; auto.
  inv B. inv H. destruct v; simpl; auto. 
  apply val_lessdef_upto_single_float. apply Float.singleoffloat_idem. 
  simpl; auto.
  apply val_lessdef_upto_single_float. rewrite H. apply Float.singleoffloat_idem.
  (* default *)
  exists x; auto.
Qed.

Inductive val_content_inject (f: meminj): memory_chunk -> val -> val -> Prop :=
  | val_content_inject_8_signed:
      forall n1 n2, Int.sign_ext 8 n1 = Int.sign_ext 8 n2 ->
      val_content_inject f Mint8signed (Vint n1) (Vint n2)
  | val_content_inject_8_unsigned:
      forall n1 n2, Int.zero_ext 8 n1 = Int.zero_ext 8 n2 ->
      val_content_inject f Mint8unsigned (Vint n1) (Vint n2)
  | val_content_inject_16_signed:
      forall n1 n2, Int.sign_ext 16 n1 = Int.sign_ext 16 n2 ->
      val_content_inject f Mint16signed (Vint n1) (Vint n2)
  | val_content_inject_16_unsigned:
      forall n1 n2, Int.zero_ext 16 n1 = Int.zero_ext 16 n2 ->
      val_content_inject f Mint16unsigned (Vint n1) (Vint n2)
  | val_content_inject_single:
      forall n1 n2, Float.singleoffloat n1 = Float.singleoffloat n2 ->
      val_content_inject f Mfloat32 (Vfloat n1) (Vfloat n2)
  | val_content_inject_base:
      forall chunk v1 v2, val_inject f v1 v2 ->
      val_content_inject f chunk v1 v2.

Hint Resolve val_content_inject_base.

Lemma eval_store_arg:
  forall f sp te tm a v va chunk,
  eval_expr tge sp te tm a va ->
  val_inject f v va ->
  exists vb,
     eval_expr tge sp te tm (store_arg chunk a) vb
  /\ val_content_inject f chunk v vb.
Proof.
  intros.
  assert (DFL: forall v', Val.lessdef va v' -> val_content_inject f chunk v v').
    intros. apply val_content_inject_base. inv H1. auto. inv H0. auto.
  destruct chunk; simpl.
  (* int8signed *)
  exploit (eval_uncast_int (Int.repr 255)); eauto. intros [v' [A B]].
  exists v'; split; auto.
  inv B; auto. inv H0; auto. constructor.
  assert (0 < 8 < Z_of_nat Int.wordsize) by (compute; auto).
  apply Int.sign_ext_equal_if_zero_equal; auto.
  repeat rewrite Int.zero_ext_and; auto.
  (* int8unsigned *)
  exploit (eval_uncast_int (Int.repr 255)); eauto. intros [v' [A B]].
  exists v'; split; auto.
  inv B; auto. inv H0; auto. constructor.
  assert (0 < 8 < Z_of_nat Int.wordsize) by (compute; auto).
  repeat rewrite Int.zero_ext_and; auto.
  (* int16signed *)
  exploit (eval_uncast_int (Int.repr 65535)); eauto. intros [v' [A B]].
  exists v'; split; auto.
  inv B; auto. inv H0; auto. constructor.
  assert (0 < 16 < Z_of_nat Int.wordsize) by (compute; auto).
  apply Int.sign_ext_equal_if_zero_equal; auto.
  repeat rewrite Int.zero_ext_and; auto.
  (* int16unsigned *)
  exploit (eval_uncast_int (Int.repr 65535)); eauto. intros [v' [A B]].
  exists v'; split; auto.
  inv B; auto. inv H0; auto. constructor.
  assert (0 < 16 < Z_of_nat Int.wordsize) by (compute; auto).
  repeat rewrite Int.zero_ext_and; auto.
  (* int32 *)
  exists va; auto.
  (* float32 *)
  exploit eval_uncast_float32; eauto. intros [v' [A B]].
  exists v'; split; auto.
  inv B; auto. inv H0; auto. constructor. auto.
  (* float64 *)
  exists va; auto.
  (* float64al32 *)
  exists va; auto.
Qed.

Lemma storev_mapped_content_inject:
  forall f chunk m1 a1 v1 n1 m2 a2 v2,
  Mem.inject f m1 m2 ->
  Mem.storev chunk m1 a1 v1 = Some n1 ->
  val_inject f a1 a2 ->
  val_content_inject f chunk v1 v2 ->
  exists n2,
    Mem.storev chunk m2 a2 v2 = Some n2 /\ Mem.inject f n1 n2.
Proof.
  intros.
  assert (forall v1',
    (forall b ofs, Mem.store chunk m1 b ofs v1 = Mem.store chunk m1 b ofs v1') ->
    Mem.storev chunk m1 a1 v1' = Some n1).
  intros. rewrite <- H0. destruct a1; simpl; auto. 
  inv H2; (eapply Mem.storev_mapped_inject; [eauto|idtac|eauto|eauto]);
  auto; apply H3; intros.
  rewrite <- Mem.store_int8_sign_ext. rewrite H4. apply Mem.store_int8_sign_ext.
  rewrite <- Mem.store_int8_zero_ext. rewrite H4. apply Mem.store_int8_zero_ext.
  rewrite <- Mem.store_int16_sign_ext. rewrite H4. apply Mem.store_int16_sign_ext.
  rewrite <- Mem.store_int16_zero_ext. rewrite H4. apply Mem.store_int16_zero_ext.
  rewrite <- Mem.store_float32_truncate. rewrite H4. apply Mem.store_float32_truncate.
Qed.

Lemma make_store_correct:
  forall f sp te tm addr tvaddr rhs tvrhs chunk m vaddr vrhs m' fn k,
  eval_expr tge sp te tm addr tvaddr ->
  eval_expr tge sp te tm rhs tvrhs ->
  Mem.storev chunk m vaddr vrhs = Some m' ->
  Mem.inject f m tm ->
  val_inject f vaddr tvaddr ->
  val_inject f vrhs tvrhs ->
  exists tm', exists tvrhs',
  step tge (State fn (make_store chunk addr rhs) k sp te tm)
        E0 (State fn Sskip k sp te tm')
  /\ Mem.storev chunk tm tvaddr tvrhs' = Some tm'
  /\ Mem.inject f m' tm'.
Proof.
  intros. unfold make_store.
  exploit eval_store_arg. eexact H0. eauto. 
  intros [tv [EVAL VCINJ]].
  exploit storev_mapped_content_inject; eauto.
  intros [tm' [STORE MEMINJ]].
  exists tm'; exists tv.
  split. eapply step_store; eauto.
  auto.
Qed.

(** Correctness of [make_unop]. *)

Lemma eval_make_unop:
  forall sp te tm a v op v',
  eval_expr tge sp te tm a v ->
  eval_unop op v = Some v' ->
  exists v'', eval_expr tge sp te tm (make_unop op a) v'' /\ Val.lessdef v' v''.
Proof.
  intros; unfold make_unop. 
  assert (DFL: exists v'', eval_expr tge sp te tm (Eunop op a) v'' /\ Val.lessdef v' v'').
    exists v'; split. econstructor; eauto. auto.
  destruct op; auto; simpl in H0; inv H0.
(* cast8unsigned *)
  exploit (eval_uncast_int (Int.repr 255)); eauto. intros [v1 [A B]].
  exists (Val.zero_ext 8 v1); split. econstructor; eauto. 
  inv B. apply Val.zero_ext_lessdef; auto. simpl.
  assert (0 < 8 < Z_of_nat Int.wordsize) by (compute; auto).
  repeat rewrite Int.zero_ext_and; auto. change (two_p 8 - 1) with 255. rewrite H0. auto. 
(* cast8signed *)
  exploit (eval_uncast_int (Int.repr 255)); eauto. intros [v1 [A B]].
  exists (Val.sign_ext 8 v1); split. econstructor; eauto. 
  inv B. apply Val.sign_ext_lessdef; auto. simpl.
  assert (0 < 8 < Z_of_nat Int.wordsize) by (compute; auto).
  replace (Int.sign_ext 8 n2) with (Int.sign_ext 8 n1). auto.
  apply Int.sign_ext_equal_if_zero_equal; auto.
  repeat rewrite Int.zero_ext_and; auto.
(* cast16unsigned *)
  exploit (eval_uncast_int (Int.repr 65535)); eauto. intros [v1 [A B]].
  exists (Val.zero_ext 16 v1); split. econstructor; eauto. 
  inv B. apply Val.zero_ext_lessdef; auto. simpl.
  assert (0 < 16 < Z_of_nat Int.wordsize) by (compute; auto).
  repeat rewrite Int.zero_ext_and; auto. change (two_p 16 - 1) with 65535. rewrite H0. auto. 
(* cast16signed *)
  exploit (eval_uncast_int (Int.repr 65535)); eauto. intros [v1 [A B]].
  exists (Val.sign_ext 16 v1); split. econstructor; eauto. 
  inv B. apply Val.sign_ext_lessdef; auto. simpl.
  assert (0 < 16 < Z_of_nat Int.wordsize) by (compute; auto).
  replace (Int.sign_ext 16 n2) with (Int.sign_ext 16 n1). auto.
  apply Int.sign_ext_equal_if_zero_equal; auto.
  repeat rewrite Int.zero_ext_and; auto.
(* singleoffloat *)
  exploit eval_uncast_float32; eauto. intros [v1 [A B]].
  exists (Val.singleoffloat v1); split. econstructor; eauto. 
  inv B. apply Val.singleoffloat_lessdef; auto. simpl. rewrite H0; auto.
Qed.

Lemma make_unop_correct:
  forall f sp te tm a v op v' tv,
  eval_expr tge sp te tm a tv ->
  eval_unop op v = Some v' ->
  val_inject f v tv ->
  exists tv', eval_expr tge sp te tm (make_unop op a) tv' /\ val_inject f v' tv'.
Proof.
  intros. exploit eval_unop_compat; eauto. intros [tv' [A B]].
  exploit eval_make_unop; eauto. intros [tv'' [C D]].
  exists tv''; split; auto. 
  inv D. auto. inv B. auto.
Qed.

(** Correctness of the variable accessor [var_addr] *)

Lemma var_addr_correct:
  forall cenv id f tf e le te sp lo hi m cs tm b,
  match_callstack f m tm (Frame cenv tf e le te sp lo hi :: cs) (Mem.nextblock m) (Mem.nextblock tm) ->
  eval_var_addr ge e id b ->
  exists tv,
     eval_expr tge (Vptr sp Int.zero) te tm (var_addr cenv id) tv
  /\ val_inject f (Vptr b Int.zero) tv.
Proof.
  unfold var_addr; intros.
  assert (match_var f sp e!id cenv!id).
    inv H. inv MENV. auto.
  inv H1; inv H0; try congruence.
  (* local *)
  exists (Vptr sp (Int.repr ofs)); split.
  eapply make_stackaddr_correct.
  congruence.
  (* global *)
  exploit match_callstack_match_globalenvs; eauto. intros [bnd MG]. inv MG.
  exists (Vptr b Int.zero); split.
  eapply make_globaladdr_correct; eauto. rewrite symbols_preserved; auto.
  econstructor; eauto.
Qed.

(** * Correctness of stack allocation of local variables *)

(** This section shows the correctness of the translation of Csharpminor
  local variables as sub-blocks of the Cminor stack data.  This is the most difficult part of the proof. *)

Remark block_alignment_pos:
  forall sz, block_alignment sz > 0.
Proof.
  unfold block_alignment; intros. 
  destruct (zlt sz 2). omega. 
  destruct (zlt sz 4). omega.
  destruct (zlt sz 8); omega.
Qed.

Remark assign_variable_incr:
  forall id sz cenv stksz cenv' stksz',
  assign_variable (cenv, stksz) (id, sz) = (cenv', stksz') -> stksz <= stksz'.
Proof.
  simpl; intros. inv H. 
  generalize (align_le stksz (block_alignment sz) (block_alignment_pos sz)).
  assert (0 <= Zmax 0 sz). apply Zmax_bound_l. omega.
  omega.
Qed.

Remark assign_variables_incr:
  forall vars cenv sz cenv' sz',
  assign_variables (cenv, sz) vars = (cenv', sz') -> sz <= sz'.
Proof.
  induction vars; intros until sz'.
  simpl; intros. inv H. omega.
Opaque assign_variable.
  destruct a as [id s]. simpl. intros.
  destruct (assign_variable (cenv, sz) (id, s)) as [cenv1 sz1]_eqn. 
  apply Zle_trans with sz1. eapply assign_variable_incr; eauto. eauto.
Transparent assign_variable.
Qed.

Remark inj_offset_aligned_block:
  forall stacksize sz,
  Mem.inj_offset_aligned (align stacksize (block_alignment sz)) sz.
Proof.
  intros; red; intros.
  apply Zdivides_trans with (block_alignment sz).
  unfold align_chunk.  unfold block_alignment.
  generalize Zone_divide; intro.
  generalize Zdivide_refl; intro.
  assert (2 | 4). exists 2; auto.
  assert (2 | 8). exists 4; auto.
  assert (4 | 8). exists 2; auto.
  destruct (zlt sz 2).
  destruct chunk; simpl in *; auto; omegaContradiction.
  destruct (zlt sz 4).
  destruct chunk; simpl in *; auto; omegaContradiction.
  destruct (zlt sz 8).
  destruct chunk; simpl in *; auto; omegaContradiction.
  destruct chunk; simpl; auto.
  apply align_divides. apply block_alignment_pos.
Qed.

Remark inj_offset_aligned_block':
  forall stacksize sz,
  Mem.inj_offset_aligned (align stacksize (block_alignment sz)) (Zmax 0 sz).
Proof.
  intros. 
  replace (block_alignment sz) with (block_alignment (Zmax 0 sz)).
  apply inj_offset_aligned_block. 
  rewrite Zmax_spec. destruct (zlt sz 0); auto.
  transitivity 1. reflexivity. unfold block_alignment. rewrite zlt_true. auto. omega.
Qed.

Lemma match_callstack_alloc_variable:
  forall id lv cenv sz cenv' sz' tm sp e tf m m' b te le lo cs f,
  assign_variable (cenv, sz) (id, lv) = (cenv', sz') ->
  Mem.valid_block tm sp ->
  (forall ofs k p,
    Mem.perm tm sp ofs k p -> 0 <= ofs < tf.(fn_stackspace)) ->
  Mem.range_perm tm sp 0 tf.(fn_stackspace) Cur Freeable ->
  tf.(fn_stackspace) <= Int.max_unsigned ->
  Mem.alloc m 0 lv = (m', b) ->
  match_callstack f m tm 
                  (Frame cenv tf e le te sp lo (Mem.nextblock m) :: cs)
                  (Mem.nextblock m) (Mem.nextblock tm) ->
  Mem.inject f m tm ->
  0 <= sz -> sz' <= tf.(fn_stackspace) ->
  (forall b delta ofs k p,
     f b = Some(sp, delta) -> Mem.perm m b ofs k p -> ofs + delta < sz) ->
  e!id = None ->
  exists f',
     inject_incr f f'
  /\ Mem.inject f' m' tm
  /\ match_callstack f' m' tm
                     (Frame cenv' tf (PTree.set id (b, lv) e) le te sp lo (Mem.nextblock m') :: cs)
                     (Mem.nextblock m') (Mem.nextblock tm)
  /\ (forall b delta ofs k p,
      f' b = Some(sp, delta) -> Mem.perm m' b ofs k p -> ofs + delta < sz').
Proof.
  intros until f. intros ASV VALID BOUNDS PERMS NOOV ALLOC MCS INJ LO HI RANGE E.
  unfold assign_variable in ASV. inv ASV.
  assert (0 <= Zmax 0 lv). apply Zmax1.
  assert (lv <= Zmax 0 lv). apply Zmax2.
  generalize (align_le sz (block_alignment lv) (block_alignment_pos lv)). intro.
  set (ofs := align sz (block_alignment lv)) in *.
  exploit Mem.alloc_left_mapped_inject. eauto. eauto. eauto. 
    instantiate (1 := ofs).
    omega.
    intros. exploit BOUNDS; eauto. omega.
    intros. apply Mem.perm_implies with Freeable; auto with mem. apply Mem.perm_cur.
    apply PERMS. omega.
    rewrite Zminus_0_r. unfold ofs. apply inj_offset_aligned_block.
    intros. generalize (RANGE _ _ _ _ _ H2 H3). omega. 
  intros [f1 [MINJ1 [INCR1 [SAME OTHER]]]].
  exists f1; split. auto. split. auto. split. 
  eapply match_callstack_alloc_left; eauto.
  intros. exploit Mem.perm_alloc_inv; eauto. destruct (zeq b0 b).
  subst b0. assert (delta = ofs) by congruence. subst delta. omega.
  intro. rewrite OTHER in H2; eauto. generalize (RANGE _ _ _ _ _ H2 H4). omega. 
Qed.

Lemma match_callstack_alloc_variables_rec:
  forall tm sp cenv' tf le te lo cs,
  Mem.valid_block tm sp ->
  (forall ofs k p,
    Mem.perm tm sp ofs k p -> 0 <= ofs < tf.(fn_stackspace)) ->
  Mem.range_perm tm sp 0 tf.(fn_stackspace) Cur Freeable ->
  tf.(fn_stackspace) <= Int.max_unsigned ->
  forall e m vars e' m',
  alloc_variables e m vars e' m' ->
  forall f cenv sz,
  assign_variables (cenv, sz) vars = (cenv', tf.(fn_stackspace)) ->
  match_callstack f m tm 
                  (Frame cenv tf e le te sp lo (Mem.nextblock m) :: cs)
                  (Mem.nextblock m) (Mem.nextblock tm) ->
  Mem.inject f m tm ->
  0 <= sz ->
  (forall b delta ofs k p,
     f b = Some(sp, delta) -> Mem.perm m b ofs k p -> ofs + delta < sz) ->
  list_norepet (map fst vars) ->
  (forall id lv, In (id, lv) vars -> e!id = None) ->
  exists f',
     inject_incr f f'
  /\ Mem.inject f' m' tm
  /\ match_callstack f' m' tm
                     (Frame cenv' tf e' le te sp lo (Mem.nextblock m') :: cs)
                     (Mem.nextblock m') (Mem.nextblock tm).
Proof.
  intros until cs. intros VALID BOUNDS PERM NOOV.
  induction 1.
  (* base case *)
  intros. simpl in H. inversion H; subst cenv sz.
  exists f. split. apply inject_incr_refl. split. auto. auto.
  (* inductive case *)
  intros until sz0. 
Opaque assign_variable.
  simpl.  caseEq (assign_variable (cenv, sz0) (id, sz)).
  intros cenv1 sz1 ASV1 ASVS MATCH MINJ SZPOS BOUND NOREPET UNDEFINED.
  assert (sz1 <= fn_stackspace tf). eapply assign_variables_incr; eauto. 
  exploit match_callstack_alloc_variable; eauto with coqlib.
  intros [f1 [INCR1 [INJ1 [MCS1 BOUND1]]]].
  exploit IHalloc_variables; eauto. 
  apply Zle_trans with sz0; auto. eapply assign_variable_incr; eauto.
  inv NOREPET; auto.
  intros. rewrite PTree.gso. eapply UNDEFINED; eauto with coqlib.
  inv NOREPET. red; intro; subst id0.
  elim H5. change id with (fst (id, lv)). apply List.in_map. auto.
  intros [f2 [INCR2 [INJ2 MCS2]]].
  exists f2; intuition. eapply inject_incr_trans; eauto. 
Qed.

Lemma create_undef_temps_val:
  forall id v temps, (create_undef_temps temps)!id = Some v -> In id temps /\ v = Vundef.
Proof.
  induction temps; simpl; intros.
  rewrite PTree.gempty in H. congruence.
  rewrite PTree.gsspec in H. destruct (peq id a).
  split. auto. congruence.
  exploit IHtemps; eauto. tauto. 
Qed.

Section BIND_PARAMETER_TEMPS.

Variable f: meminj.

Definition le_te_agree (le: Csharpminor.temp_env) (te: Cminor.env) : Prop :=
  forall id v, le!id = Some v -> exists v', te!(id) = Some v' /\ val_inject f v v'.

Fixpoint set_params' (vl: list val) (il: list ident) (te: Cminor.env) : Cminor.env :=
  match il, vl with
  | i1 :: is, v1 :: vs => set_params' vs is (PTree.set i1 v1 te)
  | i1 :: is, nil => set_params' nil is (PTree.set i1 Vundef te)
  | _, _ => te
  end.

Lemma bind_parameters_agree_rec:
  forall vars vals tvals le1 le2 te,
  bind_parameters vars vals le1 = Some le2 ->
  val_list_inject f vals tvals ->
  le_te_agree le1 te ->
  le_te_agree le2 (set_params' tvals vars te).
Proof.
Opaque PTree.set.
  induction vars; simpl; intros.
  destruct vals; try discriminate. inv H. auto. 
  destruct vals; try discriminate. inv H0.
  simpl. eapply IHvars; eauto.
  red; intros. rewrite PTree.gsspec in *. destruct (peq id a). 
  inv H0. exists v'; auto.
  apply H1; auto.
Qed.

Lemma set_params'_outside:
  forall id il vl te, ~In id il -> (set_params' vl il te)!id = te!id.
Proof.
  induction il; simpl; intros. auto. 
  destruct vl; rewrite IHil.
  apply PTree.gso. intuition. intuition.
  apply PTree.gso. intuition. intuition.
Qed.

Lemma set_params'_inside:
  forall id il vl te1 te2,
  In id il ->
  (set_params' vl il te1)!id = (set_params' vl il te2)!id.
Proof.
  induction il; simpl; intros.
  contradiction.
  destruct vl; destruct (List.in_dec peq id il); auto;
  repeat rewrite set_params'_outside; auto;
  assert (a = id) by intuition; subst a; repeat rewrite PTree.gss; auto.
Qed.

Lemma set_params_set_params':
  forall il vl id,
  list_norepet il ->
  (set_params vl il)!id = (set_params' vl il (PTree.empty val))!id.
Proof.
  induction il; simpl; intros.
  auto.
  inv H. destruct vl. 
  rewrite PTree.gsspec. destruct (peq id a). 
  subst a. rewrite set_params'_outside; auto. rewrite PTree.gss; auto.
  rewrite IHil; auto.
  destruct (List.in_dec peq id il). apply set_params'_inside; auto.
  repeat rewrite set_params'_outside; auto. rewrite PTree.gso; auto. 
  rewrite PTree.gsspec. destruct (peq id a). 
  subst a. rewrite set_params'_outside; auto. rewrite PTree.gss; auto.
  rewrite IHil; auto.
  destruct (List.in_dec peq id il). apply set_params'_inside; auto.
  repeat rewrite set_params'_outside; auto. rewrite PTree.gso; auto. 
Qed.

Lemma set_locals_outside:
  forall e id il,
  ~In id il -> (set_locals il e)!id = e!id.
Proof.
  induction il; simpl; intros.
  auto.
  rewrite PTree.gso. apply IHil. tauto. intuition. 
Qed.

Lemma set_locals_inside:
  forall e id il,
  In id il -> (set_locals il e)!id = Some Vundef.
Proof.
  induction il; simpl; intros.
  contradiction.
  destruct H. subst a. apply PTree.gss. 
  rewrite PTree.gsspec. destruct (peq id a). auto. auto. 
Qed.

Lemma set_locals_set_params':
  forall vars vals params id,
  list_norepet params ->
  list_disjoint params vars ->
  (set_locals vars (set_params vals params)) ! id =
  (set_params' vals params (set_locals vars (PTree.empty val))) ! id.
Proof.
  intros. destruct (in_dec peq id vars).
  assert (~In id params). apply list_disjoint_notin with vars; auto. apply list_disjoint_sym; auto.
  rewrite set_locals_inside; auto. rewrite set_params'_outside; auto. rewrite set_locals_inside; auto.
  rewrite set_locals_outside; auto. rewrite set_params_set_params'; auto. 
  destruct (in_dec peq id params). 
  apply set_params'_inside; auto.
  repeat rewrite set_params'_outside; auto. 
  rewrite set_locals_outside; auto. 
Qed.

Lemma bind_parameters_agree:
  forall params temps vals tvals le,
  bind_parameters params vals (create_undef_temps temps) = Some le ->
  val_list_inject f vals tvals ->
  list_norepet params ->
  list_disjoint params temps ->
  le_te_agree le (set_locals temps (set_params tvals params)).
Proof.
  intros; red; intros.
  exploit bind_parameters_agree_rec; eauto.
  instantiate (1 := set_locals temps (PTree.empty val)).
  red; intros. exploit create_undef_temps_val; eauto. intros [A B]. subst v0.
  exists Vundef; split. apply set_locals_inside; auto. auto.
  intros [v' [A B]]. exists v'; split; auto.
  rewrite <- A. apply set_locals_set_params'; auto.
Qed.

End BIND_PARAMETER_TEMPS.

(** Preservation of [match_callstack] by simultaneous allocation
  of Csharpminor local variables and of the Cminor stack data block. *)

Lemma match_callstack_alloc_variables:
  forall fn cenv tf m e m' tm tm' sp f cs args targs le,
  build_compilenv fn = (cenv, tf.(fn_stackspace)) ->
  tf.(fn_stackspace) <= Int.max_unsigned ->
  list_norepet (map fst (Csharpminor.fn_vars fn)) ->
  list_norepet (Csharpminor.fn_params fn) ->
  list_disjoint (Csharpminor.fn_params fn) (Csharpminor.fn_temps fn) ->
  alloc_variables Csharpminor.empty_env m (Csharpminor.fn_vars fn) e m' ->
  bind_parameters (Csharpminor.fn_params fn) args (create_undef_temps fn.(fn_temps)) = Some le ->
  val_list_inject f args targs ->
  Mem.alloc tm 0 tf.(fn_stackspace) = (tm', sp) ->
  match_callstack f m tm cs (Mem.nextblock m) (Mem.nextblock tm) ->
  Mem.inject f m tm ->
  let te := set_locals (Csharpminor.fn_temps fn) (set_params targs (Csharpminor.fn_params fn)) in
  exists f',
     inject_incr f f'
  /\ Mem.inject f' m' tm'
  /\ match_callstack f' m' tm'
                     (Frame cenv tf e le te sp (Mem.nextblock m) (Mem.nextblock m') :: cs)
                     (Mem.nextblock m') (Mem.nextblock tm').
Proof.
  intros. 
  unfold build_compilenv in H. 
  eapply match_callstack_alloc_variables_rec; eauto with mem.
  red; intros. eapply Mem.perm_alloc_2; eauto. 
  eapply match_callstack_alloc_right; eauto.
  change (le_te_agree f le te). eapply bind_parameters_agree; eauto.
  eapply Mem.alloc_right_inject; eauto. omega. 
  intros. elim (Mem.valid_not_valid_diff tm sp sp); eauto with mem.
  eapply Mem.valid_block_inject_2; eauto.
  intros. apply PTree.gempty. 
Qed.

(*
(** The main result in this section: the behaviour of function entry
  in the generated Cminor code (allocate stack data block and store
  parameters whose address is taken) simulates what happens at function
  entry in the original Csharpminor (allocate one block per local variable
  and initialize the blocks corresponding to function parameters). *)

Lemma function_entry_ok:
  forall fn m e m1 vargs m2 f cs tm cenv tf tm1 sp tvargs s fn' k,
  list_norepet (fn_params_names fn ++ fn_vars_names fn) ->
  alloc_variables empty_env m (fn_variables fn) e m1 ->
  bind_parameters ge e m1 fn.(Csharpminor.fn_params) vargs m2 ->
  match_callstack f m tm cs (Mem.nextblock m) (Mem.nextblock tm) ->
  build_compilenv gce fn = (cenv, tf.(fn_stackspace)) ->
  tf.(fn_stackspace) <= Int.max_unsigned ->
  Mem.alloc tm 0 tf.(fn_stackspace) = (tm1, sp) ->
  let tparams := List.map for_var (fn_params_names fn) in
  let tvars := List.map for_var (fn_vars_names fn) in
  let ttemps := List.map for_temp (Csharpminor.fn_temps fn) in
  let te := set_locals (tvars ++ ttemps) (set_params tvargs tparams) in
  val_list_inject f vargs tvargs ->
  Mem.inject f m tm ->
  store_parameters cenv fn.(Csharpminor.fn_params) = OK s ->
  exists f2, exists tm2,
     star step tge (State fn' s k (Vptr sp Int.zero) te tm1)
                E0 (State fn' Sskip k (Vptr sp Int.zero) te tm2)
  /\ Mem.inject f2 m2 tm2
  /\ inject_incr f f2
  /\ match_callstack f2 m2 tm2
       (Frame cenv tf e (create_undef_temps (Csharpminor.fn_temps fn)) te sp (Mem.nextblock m) (Mem.nextblock m1) :: cs)
       (Mem.nextblock m2) (Mem.nextblock tm2).
Proof.
  intros.
  exploit match_callstack_alloc_variables; eauto.
  intros [f1 [INCR1 [MINJ1 MATCH1]]].
  exploit vars_vals_match_holds.
    eexact H. 
    apply val_list_inject_incr with f. eauto. eauto.
    eapply bind_parameters_normalized; eauto.
  instantiate (1 := Csharpminor.fn_temps fn). 
  fold tvars. fold ttemps. fold (fn_params_names fn). fold tparams. fold te.   
  intro VVM.
  exploit store_parameters_correct.
    eauto. eauto. eapply list_norepet_append_left; eauto.
    eexact MINJ1. eexact MATCH1. eauto.
  intros [f2 [tm2 [EXEC [MINJ2 [MATCH2 INCR2]]]]].
  exists f2; exists tm2. 
  split; eauto. split; auto. split; auto. eapply inject_incr_trans; eauto. 
Qed.
*)

(** * Semantic preservation for the translation *)

(** The proof of semantic preservation uses simulation diagrams of the
  following form:
<<
       e, m1, s ----------------- sp, te1, tm1, ts
          |                                |
         t|                                |t
          v                                v
       e, m2, out --------------- sp, te2, tm2, tout
>>
  where [ts] is the Cminor statement obtained by translating the
  Csharpminor statement [s].  The left vertical arrow is an execution
  of a Csharpminor statement.  The right vertical arrow is an execution
  of a Cminor statement.  The precondition (top vertical bar)
  includes a [mem_inject] relation between the memory states [m1] and [tm1],
  and a [match_callstack] relation for any callstack having
  [e], [te1], [sp] as top frame.  The postcondition (bottom vertical bar)
  is the existence of a memory injection [f2] that extends the injection
  [f1] we started with, preserves the [match_callstack] relation for
  the transformed callstack at the final state, and validates a
  [outcome_inject] relation between the outcomes [out] and [tout].
*)

(** ** Semantic preservation for expressions *)

Remark bool_of_val_inject:
  forall f v tv b,
  Val.bool_of_val v b -> val_inject f v tv -> Val.bool_of_val tv b.
Proof.
  intros. inv H0; inv H; constructor; auto.
Qed.

Lemma transl_constant_correct:
  forall f sp cst v,
  Csharpminor.eval_constant cst = Some v ->
  let (tcst, a) := transl_constant cst in
  exists tv,
     eval_constant tge sp tcst = Some tv
  /\ val_inject f v tv
  /\ val_match_approx a v.
Proof.
  destruct cst; simpl; intros; inv H. 
  exists (Vint i); intuition. apply approx_of_int_sound.
  exists (Vfloat f0); intuition. apply approx_of_float_sound.
Qed.

Lemma transl_expr_correct:
  forall f m tm cenv tf e le te sp lo hi cs
    (MINJ: Mem.inject f m tm)
    (MATCH: match_callstack f m tm
             (Frame cenv tf e le te sp lo hi :: cs)
             (Mem.nextblock m) (Mem.nextblock tm)),
  forall a v,
  Csharpminor.eval_expr ge e le m a v ->
  forall ta app
    (TR: transl_expr cenv a = OK (ta, app)),
  exists tv,
     eval_expr tge (Vptr sp Int.zero) te tm ta tv
  /\ val_inject f v tv
  /\ val_match_approx app v.
Proof.
  induction 3; intros; simpl in TR; try (monadInv TR).
  (* Etempvar *)
  inv MATCH. inv MENV. exploit me_temps0; eauto. intros [tv [A B]]. 
  exists tv; split. constructor; auto. split. auto. exact I.
  (* Eaddrof *)
  exploit var_addr_correct; eauto. intros [tv [A B]].
  exists tv; split. auto. split. auto. red. auto.
  (* Econst *)
  exploit transl_constant_correct; eauto. 
  destruct (transl_constant cst) as [tcst a]; inv TR.
  intros [tv [A [B C]]].
  exists tv; split. constructor; eauto. eauto.
  (* Eunop *)
  exploit IHeval_expr; eauto. intros [tv1 [EVAL1 [INJ1 APP1]]].
  unfold Csharpminor.eval_unop in H0. 
  destruct (Approx.unop_is_redundant op x0) as []_eqn; inv EQ0.
  (* -- eliminated *)
  exploit approx_unop_is_redundant_sound; eauto. intros. 
  replace v with v1 by congruence.
  exists tv1; auto.
  (* -- preserved *)
  exploit make_unop_correct; eauto. intros [tv [A B]].
  exists tv; split. auto. split. auto. eapply approx_of_unop_sound; eauto.
  (* Ebinop *)
  exploit IHeval_expr1; eauto. intros [tv1 [EVAL1 [INJ1 APP1]]].
  exploit IHeval_expr2; eauto. intros [tv2 [EVAL2 [INJ2 APP2]]].
  exploit eval_binop_compat; eauto. intros [tv [EVAL INJ]].
  exists tv; split. econstructor; eauto. split. auto. eapply approx_of_binop_sound; eauto.
  (* Eload *)
  exploit IHeval_expr; eauto. intros [tv1 [EVAL1 [INJ1 APP1]]].
  exploit Mem.loadv_inject; eauto. intros [tv [LOAD INJ]].
  exists tv; split. econstructor; eauto. split. auto.
  destruct v1; simpl in H0; try discriminate. eapply approx_of_chunk_sound; eauto.
Qed.

Lemma transl_exprlist_correct:
  forall f m tm cenv tf e le te sp lo hi cs
    (MINJ: Mem.inject f m tm)
    (MATCH: match_callstack f m tm
             (Frame cenv tf e le te sp lo hi :: cs)
             (Mem.nextblock m) (Mem.nextblock tm)),
  forall a v,
  Csharpminor.eval_exprlist ge e le m a v ->
  forall ta
    (TR: transl_exprlist cenv a = OK ta),
  exists tv,
     eval_exprlist tge (Vptr sp Int.zero) te tm ta tv
  /\ val_list_inject f v tv.
Proof.
  induction 3; intros; monadInv TR.
  exists (@nil val); split. constructor. constructor.
  exploit transl_expr_correct; eauto. intros [tv1 [EVAL1 [VINJ1 APP1]]].
  exploit IHeval_exprlist; eauto. intros [tv2 [EVAL2 VINJ2]].
  exists (tv1 :: tv2); split. constructor; auto. constructor; auto.
Qed.

(** ** Semantic preservation for statements and functions *)

Inductive match_cont: Csharpminor.cont -> Cminor.cont -> compilenv -> exit_env -> callstack -> Prop :=
  | match_Kstop: forall cenv xenv,
      match_cont Csharpminor.Kstop Kstop cenv xenv nil
  | match_Kseq: forall s k ts tk cenv xenv cs,
      transl_stmt cenv xenv s = OK ts ->
      match_cont k tk cenv xenv cs ->
      match_cont (Csharpminor.Kseq s k) (Kseq ts tk) cenv xenv cs
  | match_Kseq2: forall s1 s2 k ts1 tk cenv xenv cs,
      transl_stmt cenv xenv s1 = OK ts1 ->
      match_cont (Csharpminor.Kseq s2 k) tk cenv xenv cs ->
      match_cont (Csharpminor.Kseq (Csharpminor.Sseq s1 s2) k)
                 (Kseq ts1 tk) cenv xenv cs
  | match_Kblock: forall k tk cenv xenv cs,
      match_cont k tk cenv xenv cs ->
      match_cont (Csharpminor.Kblock k) (Kblock tk) cenv (true :: xenv) cs
  | match_Kblock2: forall k tk cenv xenv cs,
      match_cont k tk cenv xenv cs ->
      match_cont k (Kblock tk) cenv (false :: xenv) cs
  | match_Kcall: forall optid fn e le k tfn sp te tk cenv xenv lo hi cs sz cenv',
      transl_funbody cenv sz fn = OK tfn ->
      match_cont k tk cenv xenv cs ->
      match_cont (Csharpminor.Kcall optid fn e le k)
                 (Kcall optid tfn (Vptr sp Int.zero) te tk)
                 cenv' nil
                 (Frame cenv tfn e le te sp lo hi :: cs).

Inductive match_states: Csharpminor.state -> Cminor.state -> Prop :=
  | match_state:
      forall fn s k e le m tfn ts tk sp te tm cenv xenv f lo hi cs sz
      (TRF: transl_funbody cenv sz fn = OK tfn)
      (TR: transl_stmt cenv xenv s = OK ts)
      (MINJ: Mem.inject f m tm)
      (MCS: match_callstack f m tm
               (Frame cenv tfn e le te sp lo hi :: cs)
               (Mem.nextblock m) (Mem.nextblock tm))
      (MK: match_cont k tk cenv xenv cs),
      match_states (Csharpminor.State fn s k e le m)
                   (State tfn ts tk (Vptr sp Int.zero) te tm)
  | match_state_seq:
      forall fn s1 s2 k e le m tfn ts1 tk sp te tm cenv xenv f lo hi cs sz
      (TRF: transl_funbody cenv sz fn = OK tfn)
      (TR: transl_stmt cenv xenv s1 = OK ts1)
      (MINJ: Mem.inject f m tm)
      (MCS: match_callstack f m tm
               (Frame cenv tfn e le te sp lo hi :: cs)
               (Mem.nextblock m) (Mem.nextblock tm))
      (MK: match_cont (Csharpminor.Kseq s2 k) tk cenv xenv cs),
      match_states (Csharpminor.State fn (Csharpminor.Sseq s1 s2) k e le m)
                   (State tfn ts1 tk (Vptr sp Int.zero) te tm)
  | match_callstate:
      forall fd args k m tfd targs tk tm f cs cenv
      (TR: transl_fundef fd = OK tfd)
      (MINJ: Mem.inject f m tm)
      (MCS: match_callstack f m tm cs (Mem.nextblock m) (Mem.nextblock tm))
      (MK: match_cont k tk cenv nil cs)
      (ISCC: Csharpminor.is_call_cont k)
      (ARGSINJ: val_list_inject f args targs),
      match_states (Csharpminor.Callstate fd args k m)
                   (Callstate tfd targs tk tm)
  | match_returnstate:
      forall v k m tv tk tm f cs cenv
      (MINJ: Mem.inject f m tm)
      (MCS: match_callstack f m tm cs (Mem.nextblock m) (Mem.nextblock tm))
      (MK: match_cont k tk cenv nil cs)
      (RESINJ: val_inject f v tv),
      match_states (Csharpminor.Returnstate v k m)
                   (Returnstate tv tk tm).

Remark val_inject_function_pointer:
  forall bound v fd f tv,
  Genv.find_funct ge v = Some fd ->
  match_globalenvs f bound ->
  val_inject f v tv ->
  tv = v.
Proof.
  intros. exploit Genv.find_funct_inv; eauto. intros [b EQ]. subst v.
  rewrite Genv.find_funct_find_funct_ptr in H.
  assert (f b = Some(b, 0)). inv H0. apply DOMAIN. eapply FUNCTIONS; eauto.
  inv H1. rewrite H2 in H5; inv H5. reflexivity.
Qed.

Lemma match_call_cont:
  forall k tk cenv xenv cs,
  match_cont k tk cenv xenv cs ->
  match_cont (Csharpminor.call_cont k) (call_cont tk) cenv nil cs.
Proof.
  induction 1; simpl; auto; econstructor; eauto.
Qed.

Lemma match_is_call_cont:
  forall tfn te sp tm k tk cenv xenv cs,
  match_cont k tk cenv xenv cs ->
  Csharpminor.is_call_cont k ->
  exists tk',
    star step tge (State tfn Sskip tk sp te tm)
               E0 (State tfn Sskip tk' sp te tm)
    /\ is_call_cont tk'
    /\ match_cont k tk' cenv nil cs.
Proof.
  induction 1; simpl; intros; try contradiction.
  econstructor; split. apply star_refl. split. exact I. econstructor; eauto.
  exploit IHmatch_cont; eauto.
  intros [tk' [A B]]. exists tk'; split.
  eapply star_left; eauto. constructor. traceEq. auto.
  econstructor; split. apply star_refl. split. exact I. econstructor; eauto.
Qed.

(** Properties of [switch] compilation *)

Remark switch_table_shift:
  forall n sl base dfl,
  switch_target n (S dfl) (switch_table sl (S base)) =
  S (switch_target n dfl (switch_table sl base)).
Proof.
  induction sl; intros; simpl. auto. destruct (Int.eq n i); auto. 
Qed.

Remark length_switch_table:
  forall sl base1 base2,
  length (switch_table sl base1) = length (switch_table sl base2).
Proof.
  induction sl; intros; simpl. auto. decEq; auto.
Qed.

Inductive transl_lblstmt_cont(cenv: compilenv) (xenv: exit_env): lbl_stmt -> cont -> cont -> Prop :=
  | tlsc_default: forall s k ts,
      transl_stmt cenv (switch_env (LSdefault s) xenv) s = OK ts ->
      transl_lblstmt_cont cenv xenv (LSdefault s) k (Kblock (Kseq ts k))
  | tlsc_case: forall i s ls k ts k',
      transl_stmt cenv (switch_env (LScase i s ls) xenv) s = OK ts ->
      transl_lblstmt_cont cenv xenv ls k k' ->
      transl_lblstmt_cont cenv xenv (LScase i s ls) k (Kblock (Kseq ts k')).

Lemma switch_descent:
  forall cenv xenv k ls body s,
  transl_lblstmt cenv (switch_env ls xenv) ls body = OK s ->
  exists k',
  transl_lblstmt_cont cenv xenv ls k k'
  /\ (forall f sp e m,
      plus step tge (State f s k sp e m) E0 (State f body k' sp e m)).
Proof.
  induction ls; intros. 
  monadInv H. econstructor; split.
  econstructor; eauto.
  intros. eapply plus_left. constructor. apply star_one. constructor. traceEq.
  monadInv H. exploit IHls; eauto. intros [k' [A B]]. 
  econstructor; split.
  econstructor; eauto.
  intros. eapply plus_star_trans. eauto. 
  eapply star_left. constructor. apply star_one. constructor. 
  reflexivity. traceEq.
Qed.

Lemma switch_ascent:
  forall f n sp e m cenv xenv k ls k1,
  let tbl := switch_table ls O in
  let ls' := select_switch n ls in
  transl_lblstmt_cont cenv xenv ls k k1 ->
  exists k2,
  star step tge (State f (Sexit (switch_target n (length tbl) tbl)) k1 sp e m)
             E0 (State f (Sexit O) k2 sp e m)
  /\ transl_lblstmt_cont cenv xenv ls' k k2.
Proof.
  induction ls; intros; unfold tbl, ls'; simpl.
  inv H. econstructor; split. apply star_refl. econstructor; eauto.
  simpl in H. inv H. 
  rewrite Int.eq_sym. destruct (Int.eq i n).
  econstructor; split. apply star_refl. econstructor; eauto. 
  exploit IHls; eauto. intros [k2 [A B]].
  rewrite (length_switch_table ls 1%nat 0%nat). 
  rewrite switch_table_shift.
  econstructor; split. 
  eapply star_left. constructor. eapply star_left. constructor. eexact A. 
  reflexivity. traceEq.
  exact B.
Qed.

Lemma switch_match_cont:
  forall cenv xenv k cs tk ls tk',
  match_cont k tk cenv xenv cs ->
  transl_lblstmt_cont cenv xenv ls tk tk' ->
  match_cont (Csharpminor.Kseq (seq_of_lbl_stmt ls) k) tk' cenv (false :: switch_env ls xenv) cs.
Proof.
  induction ls; intros; simpl.
  inv H0. apply match_Kblock2. econstructor; eauto.
  inv H0. apply match_Kblock2. eapply match_Kseq2. auto. eauto. 
Qed.

Lemma transl_lblstmt_suffix:
  forall n cenv xenv ls body ts,
  transl_lblstmt cenv (switch_env ls xenv) ls body = OK ts ->
  let ls' := select_switch n ls in
  exists body', exists ts',
  transl_lblstmt cenv (switch_env ls' xenv) ls' body' = OK ts'.
Proof.
  induction ls; simpl; intros. 
  monadInv H.
  exists body; econstructor. rewrite EQ; eauto. simpl. reflexivity.
  monadInv H.
  destruct (Int.eq i n).
  exists body; econstructor. simpl. rewrite EQ; simpl. rewrite EQ0; simpl. reflexivity.
  eauto.
Qed.

Lemma switch_match_states:
  forall fn k e le m tfn ts tk sp te tm cenv xenv f lo hi cs sz ls body tk'
    (TRF: transl_funbody cenv sz fn = OK tfn)
    (TR: transl_lblstmt cenv (switch_env ls xenv) ls body = OK ts)
    (MINJ: Mem.inject f m tm)
    (MCS: match_callstack f m tm
               (Frame cenv tfn e le te sp lo hi :: cs)
               (Mem.nextblock m) (Mem.nextblock tm))
    (MK: match_cont k tk cenv xenv cs)
    (TK: transl_lblstmt_cont cenv xenv ls tk tk'),
  exists S,
  plus step tge (State tfn (Sexit O) tk' (Vptr sp Int.zero) te tm) E0 S
  /\ match_states (Csharpminor.State fn (seq_of_lbl_stmt ls) k e le m) S.
Proof.
  intros. destruct ls; simpl.
  inv TK. econstructor; split. 
    eapply plus_left. constructor. apply star_one. constructor. traceEq.
    eapply match_state; eauto. 
  inv TK. econstructor; split.
    eapply plus_left. constructor. apply star_one. constructor. traceEq.
    eapply match_state_seq; eauto.
    simpl. eapply switch_match_cont; eauto.
Qed.

(** Commutation between [find_label] and compilation *)

Section FIND_LABEL.

Variable lbl: label.
Variable cenv: compilenv.
Variable cs: callstack.

Lemma transl_lblstmt_find_label_context:
  forall xenv ls body ts tk1 tk2 ts' tk',
  transl_lblstmt cenv (switch_env ls xenv) ls body = OK ts ->
  transl_lblstmt_cont cenv xenv ls tk1 tk2 ->
  find_label lbl body tk2 = Some (ts', tk') ->
  find_label lbl ts tk1 = Some (ts', tk').
Proof.
  induction ls; intros.
  monadInv H. inv H0. simpl. simpl in H2. replace x with ts by congruence. rewrite H1. auto.
  monadInv H. inv H0.
  eapply IHls. eauto. eauto. simpl in H6. replace x with ts0 by congruence. simpl.
  rewrite H1. auto.
Qed.

Lemma transl_find_label:
  forall s k xenv ts tk,
  transl_stmt cenv xenv s = OK ts ->
  match_cont k tk cenv xenv cs ->
  match Csharpminor.find_label lbl s k with
  | None => find_label lbl ts tk = None
  | Some(s', k') =>
      exists ts', exists tk', exists xenv',
        find_label lbl ts tk = Some(ts', tk')
     /\ transl_stmt cenv xenv' s' = OK ts'
     /\ match_cont k' tk' cenv xenv' cs
  end

with transl_lblstmt_find_label:
  forall ls xenv body k ts tk tk1,
  transl_lblstmt cenv (switch_env ls xenv) ls body = OK ts ->
  match_cont k tk cenv xenv cs ->
  transl_lblstmt_cont cenv xenv ls tk tk1 ->
  find_label lbl body tk1 = None ->
  match Csharpminor.find_label_ls lbl ls k with
  | None => find_label lbl ts tk = None
  | Some(s', k') =>
      exists ts', exists tk', exists xenv',
        find_label lbl ts tk = Some(ts', tk')
     /\ transl_stmt cenv xenv' s' = OK ts'
     /\ match_cont k' tk' cenv xenv' cs
  end.
Proof.
  intros. destruct s; try (monadInv H); simpl; auto.
  (* seq *)
  exploit (transl_find_label s1). eauto. eapply match_Kseq. eexact EQ1. eauto.  
  destruct (Csharpminor.find_label lbl s1 (Csharpminor.Kseq s2 k)) as [[s' k'] | ].
  intros [ts' [tk' [xenv' [A [B C]]]]]. 
  exists ts'; exists tk'; exists xenv'. intuition. rewrite A; auto.
  intro. rewrite H. apply transl_find_label with xenv; auto. 
  (* ifthenelse *)
  exploit (transl_find_label s1). eauto. eauto.  
  destruct (Csharpminor.find_label lbl s1 k) as [[s' k'] | ].
  intros [ts' [tk' [xenv' [A [B C]]]]]. 
  exists ts'; exists tk'; exists xenv'. intuition. rewrite A; auto.
  intro. rewrite H. apply transl_find_label with xenv; auto. 
  (* loop *)
  apply transl_find_label with xenv. auto. econstructor; eauto. simpl. rewrite EQ; auto.
  (* block *)
  apply transl_find_label with (true :: xenv). auto. constructor; auto. 
  (* switch *)
  exploit switch_descent; eauto. intros [k' [A B]].
  eapply transl_lblstmt_find_label. eauto. eauto. eauto. reflexivity.  
  (* return *)
  destruct o; monadInv H; auto.
  (* label *)
  destruct (ident_eq lbl l).
  exists x; exists tk; exists xenv; auto.
  apply transl_find_label with xenv; auto.

  intros. destruct ls; monadInv H; simpl.
  (* default *)
  inv H1. simpl in H3. replace x with ts by congruence. rewrite H2.
  eapply transl_find_label; eauto.
  (* case *)
  inv H1. simpl in H7.
  exploit (transl_find_label s). eauto. eapply switch_match_cont; eauto. 
  destruct (Csharpminor.find_label lbl s (Csharpminor.Kseq (seq_of_lbl_stmt ls) k)) as [[s' k''] | ].
  intros [ts' [tk' [xenv' [A [B C]]]]].
  exists ts'; exists tk'; exists xenv'; intuition. 
  eapply transl_lblstmt_find_label_context; eauto. 
  simpl. replace x with ts0 by congruence. rewrite H2. auto.
  intro.
  eapply transl_lblstmt_find_label. eauto. auto. eauto. 
  simpl. replace x with ts0 by congruence. rewrite H2. auto. 
Qed.

End FIND_LABEL.

Lemma transl_find_label_body:
  forall cenv xenv size f tf k tk cs lbl s' k',
  transl_funbody cenv size f = OK tf ->
  match_cont k tk cenv xenv cs ->
  Csharpminor.find_label lbl f.(Csharpminor.fn_body) (Csharpminor.call_cont k) = Some (s', k') ->
  exists ts', exists tk', exists xenv',
     find_label lbl tf.(fn_body) (call_cont tk) = Some(ts', tk')
  /\ transl_stmt cenv xenv' s' = OK ts'
  /\ match_cont k' tk' cenv xenv' cs.
Proof.
  intros. monadInv H. simpl. 
  exploit transl_find_label. eexact EQ. eapply match_call_cont. eexact H0.
  instantiate (1 := lbl). rewrite H1. auto.
Qed.

(** The simulation diagram. *)

Fixpoint seq_left_depth (s: Csharpminor.stmt) : nat :=
  match s with
  | Csharpminor.Sseq s1 s2 => S (seq_left_depth s1)
  | _ => O
  end.

Definition measure (S: Csharpminor.state) : nat :=
  match S with
  | Csharpminor.State fn s k e le m => seq_left_depth s
  | _ => O
  end.

Lemma transl_step_correct:
  forall S1 t S2, Csharpminor.step ge S1 t S2 ->
  forall T1, match_states S1 T1 ->
  (exists T2, plus step tge T1 t T2 /\ match_states S2 T2)
  \/ (measure S2 < measure S1 /\ t = E0 /\ match_states S2 T1)%nat.
Proof.
  induction 1; intros T1 MSTATE; inv MSTATE.

(* skip seq *)
  monadInv TR. left.
  dependent induction MK.
  econstructor; split. 
  apply plus_one. constructor.
  econstructor; eauto.
  econstructor; split.
  apply plus_one. constructor.
  eapply match_state_seq; eauto. 
  exploit IHMK; eauto. intros [T2 [A B]].
  exists T2; split. eapply plus_left. constructor. apply plus_star; eauto. traceEq.
  auto.
(* skip block *)
  monadInv TR. left.
  dependent induction MK.
  econstructor; split.
  apply plus_one. constructor.
  econstructor; eauto.
  exploit IHMK; eauto. intros [T2 [A B]].
  exists T2; split. eapply plus_left. constructor. apply plus_star; eauto. traceEq.
  auto.
(* skip call *)
  monadInv TR. left.
  exploit match_is_call_cont; eauto. intros [tk' [A [B C]]]. 
  exploit match_callstack_freelist; eauto. intros [tm' [P [Q R]]].
  econstructor; split.
  eapply plus_right. eexact A. apply step_skip_call. auto.
  rewrite (sig_preserved_body _ _ _ _ TRF). auto. eauto. traceEq.
  econstructor; eauto.

(* set *)
  monadInv TR.
  exploit transl_expr_correct; eauto. intros [tv [EVAL [VINJ APP]]].
  left; econstructor; split.
  apply plus_one. econstructor; eauto. 
  econstructor; eauto. 
  eapply match_callstack_set_temp; eauto. 

(* store *)
  monadInv TR.
  exploit transl_expr_correct. eauto. eauto. eexact H. eauto. 
  intros [tv1 [EVAL1 [VINJ1 APP1]]].
  exploit transl_expr_correct. eauto. eauto. eexact H0. eauto. 
  intros [tv2 [EVAL2 [VINJ2 APP2]]].
  exploit make_store_correct. eexact EVAL1. eexact EVAL2. eauto. eauto. auto. auto.
  intros [tm' [tv' [EXEC [STORE' MINJ']]]].
  left; econstructor; split.
  apply plus_one. eexact EXEC.
  econstructor; eauto.
  inv VINJ1; simpl in H1; try discriminate. unfold Mem.storev in STORE'.
  rewrite (Mem.nextblock_store _ _ _ _ _ _ H1).
  rewrite (Mem.nextblock_store _ _ _ _ _ _ STORE').
  eapply match_callstack_invariant with f0 m tm; eauto.
  intros. eapply Mem.perm_store_2; eauto. 
  intros. eapply Mem.perm_store_1; eauto.

(* call *)
  simpl in H1. exploit functions_translated; eauto. intros [tfd [FIND TRANS]].
  monadInv TR.
  exploit transl_expr_correct; eauto. intros [tvf [EVAL1 [VINJ1 APP1]]].
  assert (tvf = vf).
    exploit match_callstack_match_globalenvs; eauto. intros [bnd MG].
    eapply val_inject_function_pointer; eauto.
  subst tvf.
  exploit transl_exprlist_correct; eauto.
  intros [tvargs [EVAL2 VINJ2]].
  left; econstructor; split.
  apply plus_one. eapply step_call; eauto.
  apply sig_preserved; eauto.
  econstructor; eauto.
  eapply match_Kcall with (cenv' := cenv); eauto.
  red; auto.

(* builtin *)
  monadInv TR.
  exploit transl_exprlist_correct; eauto.
  intros [tvargs [EVAL2 VINJ2]].
  exploit match_callstack_match_globalenvs; eauto. intros [hi' MG].
  exploit external_call_mem_inject; eauto. 
  eapply inj_preserves_globals; eauto.
  intros [f' [vres' [tm' [EC [VINJ [MINJ' [UNMAPPED [OUTOFREACH [INCR SEPARATED]]]]]]]]].
  left; econstructor; split.
  apply plus_one. econstructor. eauto. 
  eapply external_call_symbols_preserved; eauto.
  exact symbols_preserved. eexact varinfo_preserved.
  assert (MCS': match_callstack f' m' tm'
                 (Frame cenv tfn e le te sp lo hi :: cs)
                 (Mem.nextblock m') (Mem.nextblock tm')).
    apply match_callstack_incr_bound with (Mem.nextblock m) (Mem.nextblock tm).
    eapply match_callstack_external_call; eauto.
    intros. eapply external_call_max_perm; eauto.
    omega. omega. 
    eapply external_call_nextblock; eauto.
    eapply external_call_nextblock; eauto.
  econstructor; eauto.
Opaque PTree.set.
  unfold set_optvar. destruct optid; simpl. 
  eapply match_callstack_set_temp; eauto. 
  auto.

(* seq *)
  monadInv TR. 
  left; econstructor; split.
  apply plus_one. constructor. 
  econstructor; eauto.
  econstructor; eauto.
(* seq 2 *)
  right. split. auto. split. auto. econstructor; eauto. 

(* ifthenelse *)
  monadInv TR.
  exploit transl_expr_correct; eauto. intros [tv [EVAL [VINJ APP]]].
  left; exists (State tfn (if b then x1 else x2) tk (Vptr sp Int.zero) te tm); split.
  apply plus_one. eapply step_ifthenelse; eauto. eapply bool_of_val_inject; eauto.
  econstructor; eauto. destruct b; auto.

(* loop *)
  monadInv TR.
  left; econstructor; split.
  apply plus_one. constructor. 
  econstructor; eauto.
  econstructor; eauto. simpl. rewrite EQ; auto. 

(* block *)
  monadInv TR.
  left; econstructor; split.
  apply plus_one. constructor. 
  econstructor; eauto.
  econstructor; eauto.

(* exit seq *)
  monadInv TR. left.
  dependent induction MK.
  econstructor; split. 
  apply plus_one. constructor.
  econstructor; eauto. simpl. auto.
  exploit IHMK; eauto. intros [T2 [A B]].
  exists T2; split; auto. eapply plus_left. constructor. apply plus_star; eauto. traceEq.
  exploit IHMK; eauto. intros [T2 [A B]].
  exists T2; split; auto. eapply plus_left.
  simpl. constructor. apply plus_star; eauto. traceEq.

(* exit block 0 *)
  monadInv TR. left.
  dependent induction MK.
  econstructor; split.
  simpl. apply plus_one. constructor. 
  econstructor; eauto.
  exploit IHMK; eauto. intros [T2 [A B]].
  exists T2; split; auto. simpl. 
  eapply plus_left. constructor. apply plus_star; eauto. traceEq.

(* exit block n+1 *)
  monadInv TR. left.
  dependent induction MK.
  econstructor; split.
  simpl. apply plus_one. constructor. 
  econstructor; eauto. auto. 
  exploit IHMK; eauto. intros [T2 [A B]].
  exists T2; split; auto. simpl. 
  eapply plus_left. constructor. apply plus_star; eauto. traceEq.

(* switch *)
  monadInv TR. left.
  exploit transl_expr_correct; eauto. intros [tv [EVAL [VINJ APP]]].
  inv VINJ.
  exploit switch_descent; eauto. intros [k1 [A B]].
  exploit switch_ascent; eauto. intros [k2 [C D]].
  exploit transl_lblstmt_suffix; eauto. simpl. intros [body' [ts' E]].
  exploit switch_match_states; eauto. intros [T2 [F G]].
  exists T2; split.
  eapply plus_star_trans. eapply B.  
  eapply star_left. econstructor; eauto. 
  eapply star_trans. eexact C. 
  apply plus_star. eexact F.
  reflexivity. reflexivity. traceEq.
  auto.

(* return none *)
  monadInv TR. left.
  exploit match_callstack_freelist; eauto. intros [tm' [A [B C]]].
  econstructor; split.
  apply plus_one. eapply step_return_0. eauto.
  econstructor; eauto. eapply match_call_cont; eauto.
  simpl; auto.

(* return some *)
  monadInv TR. left. 
  exploit transl_expr_correct; eauto. intros [tv [EVAL [VINJ APP]]].
  exploit match_callstack_freelist; eauto. intros [tm' [A [B C]]].
  econstructor; split.
  apply plus_one. eapply step_return_1. eauto. eauto. 
  econstructor; eauto. eapply match_call_cont; eauto.

(* label *)
  monadInv TR.
  left; econstructor; split.
  apply plus_one. constructor.
  econstructor; eauto.

(* goto *)
  monadInv TR.
  exploit transl_find_label_body; eauto. 
  intros [ts' [tk' [xenv' [A [B C]]]]].
  left; econstructor; split.
  apply plus_one. apply step_goto. eexact A. 
  econstructor; eauto.

(* internal call *)
  monadInv TR. generalize EQ; clear EQ; unfold transl_function.
  caseEq (build_compilenv f). intros ce sz BC.
  destruct (zle sz Int.max_unsigned); try congruence.
  intro TRBODY.
  generalize TRBODY; intro TMP. monadInv TMP.
  set (tf := mkfunction (Csharpminor.fn_sig f) 
                        (Csharpminor.fn_params f)
                        (Csharpminor.fn_temps f)
                        sz
                        x0) in *.
  caseEq (Mem.alloc tm 0 (fn_stackspace tf)). intros tm' sp ALLOC'.
  exploit match_callstack_alloc_variables; eauto. simpl; eauto. simpl; auto.
  intros [f2 [IINCR [MINJ2 MCS2]]].
  left; econstructor; split.
  apply plus_one. constructor; simpl; eauto. 
  econstructor. eexact TRBODY. eauto. eexact MINJ2. eexact MCS2.
  inv MK; simpl in ISCC; contradiction || econstructor; eauto.

(* external call *)
  monadInv TR. 
  exploit match_callstack_match_globalenvs; eauto. intros [hi MG].
  exploit external_call_mem_inject; eauto. 
  eapply inj_preserves_globals; eauto.
  intros [f' [vres' [tm' [EC [VINJ [MINJ' [UNMAPPED [OUTOFREACH [INCR SEPARATED]]]]]]]]].
  left; econstructor; split.
  apply plus_one. econstructor.
  eapply external_call_symbols_preserved; eauto.
  exact symbols_preserved. eexact varinfo_preserved.
  econstructor; eauto.
  apply match_callstack_incr_bound with (Mem.nextblock m) (Mem.nextblock tm).
  eapply match_callstack_external_call; eauto.
  intros. eapply external_call_max_perm; eauto.
  omega. omega.
  eapply external_call_nextblock; eauto.
  eapply external_call_nextblock; eauto.

(* return *)
  inv MK. simpl.
  left; econstructor; split.
  apply plus_one. econstructor; eauto. 
  unfold set_optvar. destruct optid; simpl; econstructor; eauto.
  eapply match_callstack_set_temp; eauto. 
Qed.

Lemma match_globalenvs_init:
  forall m,
  Genv.init_mem prog = Some m ->
  match_globalenvs (Mem.flat_inj (Mem.nextblock m)) (Mem.nextblock m).
Proof.
  intros. constructor.
  apply Mem.nextblock_pos.
  intros. unfold Mem.flat_inj. apply zlt_true; auto. 
  intros. unfold Mem.flat_inj in H0. 
  destruct (zlt b1 (Mem.nextblock m)); congruence.
  intros. eapply Genv.find_symbol_not_fresh; eauto.
  intros. eapply Genv.find_funct_ptr_not_fresh; eauto.
  intros. eapply Genv.find_var_info_not_fresh; eauto. 
Qed.

Lemma transl_initial_states:
  forall S, Csharpminor.initial_state prog S ->
  exists R, Cminor.initial_state tprog R /\ match_states S R.
Proof.
  induction 1.
  exploit function_ptr_translated; eauto. intros [tf [FIND TR]].
  econstructor; split.
  econstructor.
  apply (Genv.init_mem_transf_partial _ _ TRANSL). eauto. 
  simpl. fold tge. rewrite symbols_preserved.
  replace (prog_main tprog) with (prog_main prog). eexact H0.
  symmetry. unfold transl_program in TRANSL.
  eapply transform_partial_program_main; eauto.
  eexact FIND. 
  rewrite <- H2. apply sig_preserved; auto.
  eapply match_callstate with (f := Mem.flat_inj (Mem.nextblock m0)) (cs := @nil frame) (cenv := PTree.empty Z).
  auto.
  eapply Genv.initmem_inject; eauto.
  apply mcs_nil with (Mem.nextblock m0). apply match_globalenvs_init; auto. omega. omega.
  constructor. red; auto.
  constructor. 
Qed.

Lemma transl_final_states:
  forall S R r,
  match_states S R -> Csharpminor.final_state S r -> Cminor.final_state R r.
Proof.
  intros. inv H0. inv H. inv MK. inv RESINJ. constructor.
Qed.

Theorem transl_program_correct:
  forward_simulation (Csharpminor.semantics prog) (Cminor.semantics tprog).
Proof.
  eapply forward_simulation_star; eauto.
  eexact symbols_preserved.
  eexact transl_initial_states.
  eexact transl_final_states.
  eexact transl_step_correct. 
Qed.

End TRANSLATION.
