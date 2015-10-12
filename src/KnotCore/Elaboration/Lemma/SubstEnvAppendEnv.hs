
module KnotCore.Elaboration.Lemma.SubstEnvAppendEnv where

import Control.Applicative

import qualified Coq.Syntax as Coq

import KnotCore.Syntax
import KnotCore.Elaboration.Core

lemmas :: Elab m => [EnvDecl] -> m [Coq.Sentence]
lemmas eds = sequence
  [ eEnvDecl (typeNameOf mv) (typeNameOf ed)
  | ed <- eds
  , EnvCtorCons _ mv _ <- edCtors ed
  ]

eEnvDecl :: Elab m => NamespaceTypeName -> EnvTypeName -> m Coq.Sentence
eEnvDecl ntn etn = localNames $ do

  lemma      <- idLemmaSubstEnvAppendEnv ntn etn

  (stnSub,_) <- getNamespaceCtor ntn

  x          <- freshTraceVar ntn
  s          <- freshSubtreeVar stnSub
  d1         <- freshEnvVar etn
  d2         <- freshEnvVar etn

  statement  <-
    Coq.TermForall
    <$> sequence [toBinder x, toBinder s, toBinder d1, toBinder d2]
    <*> (Coq.TermEq
         <$> toTerm (ESubst (TVar x) (SVar s) (EAppend (EVar d1) (EVar d2)))
         <*> toTerm (EAppend
                      (ESubst (TVar x) (SVar s) (EVar d1))
                      (ESubst (TWeaken (TVar x) (HVDomainEnv (EVar d1))) (SVar s) (EVar d2)))
        )

  let assertion :: Coq.Assertion
      assertion = Coq.Assertion Coq.AssLemma lemma [] statement

      proof :: Coq.Proof
      proof = Coq.ProofQed [Coq.PrTactic "needleGenericSubstEnvAppendEnv" []]

  return $ Coq.SentenceAssertionProof assertion proof
