module Lamdu.ExampleDB(initDB, createBuiltins) where

import Control.Applicative (liftA2)
import Control.Lens.Operators
import Control.Monad (join, unless, (<=<))
import Control.Monad.Trans.Class (lift)
import Control.MonadA (MonadA)
import Data.Binary (Binary(..))
import Data.Foldable (traverse_)
import Data.Store.Db (Db)
import Data.Store.IRef (IRef, Tag)
import Data.Store.Rev.Branch (Branch)
import Data.Store.Rev.Version (Version)
import Data.Store.Transaction (Transaction, setP)
import Data.Traversable (traverse)
import Lamdu.Data.Definition (Definition(..))
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.Writer as Writer
import qualified Data.Store.IRef as IRef
import qualified Data.Store.Rev.Branch as Branch
import qualified Data.Store.Rev.Version as Version
import qualified Data.Store.Rev.View as View
import qualified Data.Store.Transaction as Transaction
import qualified Lamdu.Anchors as A
import qualified Lamdu.BranchGUI as BranchGUI
import qualified Lamdu.CodeEdit.FFI as FFI
import qualified Lamdu.Data.Definition as Definition
import qualified Lamdu.Data.Expression as Expr
import qualified Lamdu.Data.Expression.IRef as ExprIRef
import qualified Lamdu.Data.Expression.Lens as ExprLens
import qualified Lamdu.Data.Expression.Utils as ExprUtil
import qualified Lamdu.Data.Ops as DataOps
import qualified Lamdu.WidgetIds as WidgetIds

newTodoIRef :: MonadA m => Transaction m (IRef (Tag m) a)
newTodoIRef = fmap IRef.unsafeFromGuid Transaction.newKey

fixIRef ::
  (Binary a, MonadA m) =>
  (IRef (Tag m) a -> Transaction m a) ->
  Transaction m (IRef (Tag m) a)
fixIRef createOuter = do
  x <- newTodoIRef
  Transaction.writeIRef x =<< createOuter x
  return x

createBuiltins ::
  MonadA m => Transaction m ((FFI.Env (Tag m), A.SpecialFunctions (Tag m)), [ExprIRef.DefI (Tag m)])
createBuiltins =
  Writer.runWriterT $ do
    list <- mkType . DataOps.newBuiltin "Data.List.List" =<< lift setToSet
    let listOf = mkApply list
    bool <- mkType . DataOps.newBuiltin "Prelude.Bool" =<< lift set

    _ <- tellift $ DataOps.newBuiltin "Data.Map.Map" =<< mkPi set (endo set)

    cons <- tellift $ DataOps.newBuiltin "Prelude.:" =<<
      forAll "a" (\a -> mkPi a . endo $ listOf a)
    nil <- tellift $ DataOps.newBuiltin "Prelude.[]" =<< forAll "a" listOf

    true <- makeWithType "Prelude.True" bool
    false <- makeWithType "Prelude.False" bool

    traverse_ ((`makeWithType_` mkPi bool (endo bool)) . ("Prelude."++))
      ["&&", "||"]

    makeWithType_ "Prelude.if" . forAll "a" $ \a ->
      mkPiRecord
      [ ("condition", bool)
      , ("then", a)
      , ("else", a)
      ] a

    makeWithType_ "Prelude.id" $ forAll "a" endo

    makeWithType_ "Prelude.const" .
      forAll "a" $ \a -> forAll "b" $ \b -> mkPi a $ mkPi b a

    makeWithType_ "Data.List.reverse" $ forAll "a" (endo . listOf)
    makeWithType_ "Data.List.tail" $ forAll "a" (endo . listOf)
    makeWithType_ "Data.List.head" . forAll "a" $ join (mkPi . listOf)

    makeWithType_ "Data.List.length" . forAll "a" $ \a ->
      mkPi (listOf a) integer

    makeWithType_ "Prelude.product" . forAll "a" $ \a ->
      mkPi (listOf a) a
    makeWithType_ "Prelude.sum" . forAll "a" $ \a ->
      mkPi (listOf a) a

    let
      filterType =
        forAll "a" $ \a ->
        mkPiRecord
        [ ("list", listOf a)
        , ("predicate", mkPi a bool)
        ] $ listOf a
    makeWithType_ "Data.List.filter" filterType
    makeWithType_ "Data.List.takeWhile" filterType

    makeWithType_ "Data.List.replicate" . forAll "a" $ \a ->
      mkPiRecord
      [ ("item", a)
      , ("count", integer)
      ] $ listOf a

    makeWithType_ "Data.List.foldl" . forAll "a" $ \a -> forAll "b" $ \b ->
      mkPiRecord
      [ ( "list", listOf b )
      , ( "initial", a )
      , ( "next"
        , mkPiRecord
          [ ("accumulator", a)
          , ("item", b)
          ] a
        )
      ] a

    makeWithType_ "Data.List.zipWith" . forAll "a" $ \a -> forAll "b" $ \b -> forAll "c" $ \c ->
      mkPiRecord
      [ ( "func", mkPiRecord [("x", a), ("y", b)] c)
      , ( "xs", listOf a )
      , ( "ys", listOf b )
      ] $ listOf c

    let aToAToA = forAll "a" $ \a -> mkPi a $ endo a
    traverse_ ((`makeWithType_` aToAToA) . ("Prelude." ++))
      ["+", "-", "*", "/", "^", "++", "div", "quot", "rem"]
    newDef "%" ["Prelude"] "mod" aToAToA
    makeWithType_ "Prelude.negate" $ forAll "a" endo
    makeWithType_ "Prelude.sqrt" $ forAll "a" endo

    let aToAToBool = forAll "a" $ \a -> mkPi a $ mkPi a bool
    traverse_ ((`makeWithType_` aToAToBool) . ("Prelude." ++))
      ["==", "/=", "<=", ">=", "<", ">"]

    newDef ".." ["Prelude"] "enumFromTo" .
      mkPi integer . mkPi integer $ listOf integer

    makeWithType_ "Data.List.iterate" .
      forAll "a" $ \a ->
      mkPiRecord [("step", endo a), ("initial", a)] $ listOf a

    newDef "." ["Prelude"] "." .
      forAll "a" $ \a -> forAll "b" $ \b -> forAll "c" $ \c ->
      mkPi (mkPi b c) . mkPi (mkPi a b) $ mkPi a c
    let
      specialFunctions = A.SpecialFunctions
        { A.sfCons = cons
        , A.sfNil = nil
        }
      ffiEnv = FFI.Env
        { FFI.trueDef = true
        , FFI.falseDef = false
        }
    return (ffiEnv, specialFunctions)
  where
    newDef name ffiPath ffiName mkTypeI = tellift_ $ do
      typeI <- mkTypeI
      DataOps.newDefinition name .
        (`Definition` typeI) . Definition.BodyBuiltin .
        Definition.Builtin $ Definition.FFIName ffiPath ffiName
    endo = join mkPi
    set = ExprIRef.newExprBody $ Expr.BodyLeaf Expr.Set
    integer = ExprIRef.newExprBody $ Expr.BodyLeaf Expr.IntegerType
    forAll name f = fmap ExprIRef.ExpressionI . fixIRef $ \aI -> do
      let aGuid = IRef.guid aI
      setP (A.assocNameRef aGuid) name
      s <- set
      return . ExprUtil.makePi aGuid s =<<
        f ((ExprIRef.newExprBody . Lens.review ExprLens.bodyParameterRef) aGuid)
    setToSet = mkPi set set
    tellift f = do
      x <- lift f
      Writer.tell [x]
      return x
    tellift_ = (fmap . fmap . const) () tellift
    mkPi mkArgType mkResType = fmap snd . join $ liftA2 ExprIRef.newPi mkArgType mkResType
    mkApply mkFunc mkArg =
      ExprIRef.newExprBody =<< liftA2 ExprUtil.makeApply mkFunc mkArg
    mkTag name = do
      tagGuid <- Transaction.newKey
      setP (A.assocNameRef tagGuid) name
      ExprIRef.newExprBody $ ExprLens.bodyTag # tagGuid
    mkRecordType strFields = do
      tagFields <- traverse (Lens._1 mkTag <=< Lens.sequenceOf Lens._2) strFields
      ExprIRef.newExprBody $ Expr.BodyRecord Expr.Record
        { Expr._recordKind = Expr.Type
        , Expr._recordFields = tagFields
        }
    mkPiRecord = mkPi . mkRecordType
    mkType f = do
      x <- lift f
      Writer.tell [x]
      return . ExprIRef.newExprBody $ Lens.review ExprLens.bodyDefinitionRef x
    makeWithType_ = (fmap . fmap . fmap . const) () makeWithType
    makeWithType builtinName typeMaker =
      tellift (DataOps.newBuiltin builtinName =<< typeMaker)

newBranch :: MonadA m => String -> Version (Tag m) -> Transaction m (Branch (Tag m))
newBranch name ver = do
  branch <- Branch.new ver
  setP (BranchGUI.branchNameProp branch) name
  return branch

initDB :: Db -> IO ()
initDB db =
  A.runDbTransaction db $ do
    exists <- Transaction.irefExists $ A.branches A.revisionIRefs
    unless exists $ do
      emptyVersion <- Version.makeInitialVersion []
      master <- newBranch "master" emptyVersion
      view <- View.new master
      let writeRevAnchor f = Transaction.writeIRef (f A.revisionIRefs)
      writeRevAnchor A.view view
      writeRevAnchor A.branches [master]
      writeRevAnchor A.currentBranch master
      writeRevAnchor A.redos []
      let paneWId = WidgetIds.fromIRef $ A.panes A.codeIRefs
      writeRevAnchor A.cursor paneWId
      A.runViewTransaction view $ do
        ((ffiEnv, specialFunctions), builtins) <- createBuiltins
        let writeCodeAnchor f = Transaction.writeIRef (f A.codeIRefs)
        writeCodeAnchor A.clipboards []
        writeCodeAnchor A.specialFunctions specialFunctions
        writeCodeAnchor A.ffiEnv ffiEnv
        writeCodeAnchor A.globals builtins
        writeCodeAnchor A.panes []
        writeCodeAnchor A.preJumps []
        writeCodeAnchor A.preCursor paneWId
        writeCodeAnchor A.postCursor paneWId
        writeCodeAnchor A.tags []
      -- Prevent undo into the invalid empty revision
      newVer <- Branch.curVersion master
      Version.preventUndo newVer
