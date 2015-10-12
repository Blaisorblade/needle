
module KnotCore.Elaboration.Lemma.SubstHvlWfTerm where

import Control.Applicative
import Control.Monad
import Data.Maybe

import Coq.Syntax as Coq
import Coq.StdLib

import KnotCore.Syntax
import KnotCore.Elaboration.Core
import KnotCore.Elaboration.Eq

lemmas :: Elab m => [SortGroupDecl] -> m [Sentence]
lemmas sdgs = do
  ntns <- getNamespaces
  concat <$> sequence
    [ sortGroupDecl ntna sdg
    | sdg <- sdgs, ntna <- ntns
    ]

sortGroupDecl :: Elab m => NamespaceTypeName -> SortGroupDecl -> m [Sentence]
sortGroupDecl ntna (SortGroupDecl sgtn sds deps hasBs) = localNames $ do

  (stna,_)   <- getNamespaceCtor ntna

  groupLemma <- idGroupLemmaSubstWellFormedSort ntna sgtn

  h          <- freshHVarlistVar
  ta         <- freshSubtreeVar stna
  wfta       <- freshVariable "wf" =<< toTerm (WfTerm (HVVar h) (SVar ta))

  h1         <- freshHVarlistVar
  induction  <- idInductionWellFormedSortGroup sgtn

  assertions <- forM sds (localNames . sortAssertion h ta wfta h1 ntna . typeNameOf)
  proofs     <- concat <$> mapM (sortProof (map typeNameOf sds) hasBs h ta wfta h1 ntna) sds


  binders    <-
    if ntna `elem` deps
    then sequence
         [ toImplicitBinder h
         , toImplicitBinder ta
         , toBinder wfta
         ]
    else sequence
         [ toImplicitBinder h ]
  refwfta    <- toRef wfta
  bindh1     <- toBinder h1
  refh1      <- toRef h1

  definition <-
      Definition
      <$> toId groupLemma
      <*> pure binders
      <*> pure
            (Just
               (TermForall
                  [bindh1]
                  (TermAnd
                     [ TermForall binders' assert
                     | (binders',assert) <- assertions
                     ]
                  )
               )
            )
      <*> (if hasBs
           then TermApp
                <$> toRef induction
                <*> pure
                    ([ TermAbs (bindh1:binders') assert
                     | (binders',assert) <- assertions
                     ] ++ proofs
                    )
           else TermAbs [bindh1]
                <$> (TermApp
                     <$> toRef induction
                     <*> pure
                         (refh1:
                          [ TermAbs binders' assert
                          | (binders',assert) <- assertions
                          ] ++ proofs
                         )
                    )
          )

  individual <-
    case sds of
      [_] -> return []
      _   -> forM sds $ \sd -> do
               lemma             <- idLemmaSubstWellFormedSort ntna (typeNameOf sd)
               groupLemmaRef     <- toRef groupLemma
               (binders',assert) <- sortAssertion h ta wfta h1 ntna (typeNameOf sd)
               let proof =
                     ProofQed
                       [ PrApply (TermApp groupLemmaRef ([refwfta | ntna `elem` deps ] ++ [refh1]))
                       , PrTactic "auto" []
                       ]
               return (SentenceAssertionProof
                         (Assertion AssLemma lemma (binders++[bindh1]++binders') assert)
                         proof)

  return $ SentenceDefinition definition : individual

sortAssertion :: Elab m => HVarlistVar -> SubtreeVar -> Coq.Variable -> HVarlistVar -> NamespaceTypeName -> SortTypeName -> m ([Binder],Term)
sortAssertion h ta _ h1 ntn stn = do

  t    <- freshSubtreeVar stn
  wft  <- freshVariable "wf" =<<
          toTerm (WfTerm (HVVar h1) (SVar t))
  x    <- freshTraceVar ntn
  h2   <- freshHVarlistVar

  binders <-
    sequence
    [ toBinder t
    , toBinder wft
    ]
  assert <-
    TermForall
    <$> sequence
        [ toImplicitBinder x
        , toImplicitBinder h2
        ]
    <*> (TermFunction
         <$> toTerm (SubstHvl (HVVar h) (TVar x) (HVVar h1) (HVVar h2))
         <*> toTerm (WfTerm (HVVar h2) (SSubst' (TVar x) (SVar ta) (SVar t)))
        )
  return (binders,assert)

sortProof :: Elab m => [SortTypeName] -> Bool -> HVarlistVar -> SubtreeVar -> Coq.Variable -> HVarlistVar -> NamespaceTypeName -> SortDecl -> m [Term]
sortProof stns hasBs h ta wfta h1 ntna = mapM (ctorProof stns hasBs h ta wfta h1 ntna) . sdCtors

ctorProof :: Elab m => [SortTypeName] -> Bool -> HVarlistVar -> SubtreeVar -> Coq.Variable -> HVarlistVar -> NamespaceTypeName -> CtorDecl -> m Term
ctorProof stns hasBs h _ wfta h1 ntna cd = localNames $ do

  xa   <- freshTraceVar ntna
  h2   <- freshHVarlistVar
  del  <- freshVariable "del" =<<
          toTerm (SubstHvl (HVVar h) (TVar xa) (HVVar h1) (HVVar h2))

  case cd of
    CtorVar cn mv -> do
      i    <- freshIndexVar (typeNameOf mv)
      wfi  <- freshVariable "wfi" =<<
              toTerm (WfIndex (HVVar h1) (IVar i))

      TermAbs
        <$> sequence
            ( [ toBinder h1 | hasBs ] ++
              [ toImplicitBinder i
              , toBinder wfi
              , toImplicitBinder xa
              , toImplicitBinder h2
              , toBinder del
              ]
            )
        <*> (if typeNameOf mv == ntna
             then
               TermApp
               <$> (idLemmaSubstHvlWfIndex ntna (typeNameOf mv) >>= toRef)
               <*> sequence
                   [ toRef wfta
                   , toRef del
                   , toRef wfi
                   ]
             else
               TermApp
               <$> (idRelationWellFormedCtor cn >>= toRef)
               <*> sequence
                   [ toRef h2
                   , TermApp
                     <$> (idLemmaSubstHvlWfIndex ntna (typeNameOf mv) >>= toRef)
                     <*> sequence
                         [ toRef del
                         , toRef wfi
                         ]
                   ]
            )

    CtorTerm cn fds -> do

      (binderss,proofs) <-
        unzip . catMaybes
        <$> (forM fds $ \fd ->
               case fd of
                 FieldBinding _     -> return Nothing
                 FieldSubtree sv bs
                   | typeNameOf sv `elem` stns -> do
                       let ebs = simplifyHvl $ evalBindSpec bs

                       wf      <- freshVariable "wf" =<<
                                  toTerm (WfTerm (simplifyHvlAppend (HVVar h1) ebs) (SVar sv))
                       ih      <- freshInductionHypothesis sv
                       binders <- sequence [ toBinder sv, toBinder wf, toBinder ih ]
                       proof   <- TermApp
                                  <$> toRef ih
                                  <*> sequence
                                      [ toTerm (TWeaken (TVar xa) ebs)
                                      , toTerm (simplifyHvlAppend (HVVar h2) ebs)
                                      , TermApp
                                        <$> (idLemmaWeakenSubstHvl ntna >>= toRef)
                                        <*> sequence
                                            [ toTerm ebs
                                            , toRef del
                                            ]
                                      ]
                       substbs <- eqhvlEvalBindspecSubst ntna bs
                       proof' <- case eqhSimplify (EqhCongAppend (EqhRefl (HVVar h2)) (EqhSym substbs)) of
                                   EqhRefl _ -> pure proof
                                   eq        -> TermApp (termIdent "eq_ind2")
                                                <$> sequence
                                                    [ idRelationWellFormed (typeNameOf sv) >>= toRef
                                                    , toTerm eq
                                                    , toTerm (EqtRefl (typeNameOf sv))
                                                    , pure proof
                                                    ]
                       return $ Just (binders, proof')

                   | otherwise -> do
                       let ebs = evalBindSpec bs
                       deps    <- getSortNamespaceDependencies (sortOf sv)

                       wf      <- freshVariable "wf" =<<
                                  toTerm (WfTerm (simplifyHvlAppend (HVVar h1) ebs) (SVar sv))
                       binders <- sequence [ toBinder sv, toBinder wf ]
                       proof   <- TermApp
                                  <$> (idLemmaSubstWellFormedSort ntna (typeNameOf sv) >>= toRef)
                                  <*> sequence
                                      ([ toRef wfta | ntna `elem` deps ] ++
                                       [ toRef h1
                                       , toRef sv
                                       , toRef wf
                                       , TermApp
                                         <$> (idLemmaWeakenSubstHvl ntna >>= toRef)
                                         <*> sequence
                                             [ toTerm ebs
                                             , toRef del
                                             ]
                                       ]
                                      )

                       return $ Just (binders, proof))

      bindh1   <- toBinder h1
      bindx    <- toImplicitBinder xa
      bindh2   <- toImplicitBinder h2
      binddel  <- toBinder del
      refh2    <- toRef h2

      let binders = concat
                      [ [bindh1 | hasBs ]
                      , concat binderss
                      , [bindx, bindh2, binddel]
                      ]

      TermAbs
        <$> pure binders
        <*> (TermApp
             <$> (idRelationWellFormedCtor cn >>= toRef)
             <*> pure (refh2 : proofs)
            )
