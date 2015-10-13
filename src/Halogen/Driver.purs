module Halogen.Driver
  ( Driver()
  , runUI
  ) where

import Prelude

import Control.Coroutine (Consumer(), await)
import Control.Monad.Aff (Aff())
import Control.Monad.Aff.AVar (AVar(), makeVar, putVar, takeVar)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Free (Free(), runFreeM)
import Control.Monad.Rec.Class (forever)
import Control.Monad.State (runState)
import Control.Monad.Trans (lift)

import Data.Functor.Coproduct (Coproduct(), coproduct)
import Data.NaturalTransformation (Natural())
import Data.Tuple (Tuple(..))
import Data.Void (Void())

import DOM.HTML.Types (HTMLElement())

import Halogen.Component (Component(), renderComponent, queryComponent)
import Halogen.Effects (HalogenEffects())
import Halogen.HTML.Renderer.VirtualDOM (RenderState(), emptyRenderState, renderHTML)
import Halogen.Internal.VirtualDOM (VTree(), createElement, diff, patch)
import Halogen.Query (HalogenF())
import Halogen.Query.StateF (StateF(), stateN)
import Halogen.Query.SubscribeF (SubscribeF(), subscribeN)

-- | Type alias for driver functions generated by runUI - a driver takes an
-- | input of the query algebra (`f`) and returns an `Aff` that returns when
-- | query has been fulfilled.
type Driver f eff = Natural f (Aff (HalogenEffects eff))

-- | Type alias used internally to track the driver's persistent state.
type DriverState s =
  { node :: HTMLElement
  , vtree :: VTree
  , state :: s
  , memo :: RenderState
  , renderPending :: Boolean
  }

-- | Runs the top level UI component for a Halogen app, returning a generated
-- | HTML element that can be attached to the DOM and a driver function that
-- | can be used to send actions and requests into the component (see the
-- | [`action`](#action), [`request`](#request), and related variations for
-- | more details on querying the driver).
runUI :: forall s f eff. Component s f (Aff (HalogenEffects eff)) Void
      -> s
      -> Aff (HalogenEffects eff) { node :: HTMLElement, driver :: Driver f eff }
runUI c s = case renderComponent c s of
    Tuple html s' -> do
      ref <- makeVar
      case renderHTML (driver ref) html emptyRenderState of
        Tuple vtree memo -> do
          let node = createElement vtree
          putVar ref { node: node, vtree: vtree, state: s', memo: memo, renderPending: false }
          pure { node: node, driver: driver ref }

  where

  driver :: AVar (DriverState s) -> Driver f eff
  driver ref q = do
    x <- runFreeM (eval ref) (queryComponent c q)
    render ref
    pure x

  eval :: AVar (DriverState s)
       -> Natural (HalogenF s f (Aff (HalogenEffects eff)))
                  (Aff (HalogenEffects eff))
  eval ref = coproduct evalState (coproduct runSubscribe runAff)
    where
    evalState :: Natural (StateF s) (Aff (HalogenEffects eff))
    evalState i = do
      ds <- takeVar ref
      case runState (stateN i) ds.state of
        Tuple i' s' -> do
          putVar ref { node: ds.node, vtree: ds.vtree, state: s', memo: ds.memo, renderPending: true }
          pure i'

    runAff :: Natural (Aff (HalogenEffects eff)) (Aff (HalogenEffects eff))
    runAff g = do
      render ref
      g

    runSubscribe :: Natural (SubscribeF f (Aff (HalogenEffects eff))) (Aff (HalogenEffects eff))
    runSubscribe = subscribeN $ forever $ await >>= lift <<< driver ref

  render :: AVar (DriverState s) -> Aff (HalogenEffects eff) Unit
  render ref = do
    ds <- takeVar ref
    if not ds.renderPending
      then putVar ref ds
      else case renderComponent c ds.state of
        Tuple html s'' -> do
          case renderHTML (driver ref) html ds.memo of
            Tuple vtree' memo' -> do
              node' <- liftEff $ patch (diff ds.vtree vtree') ds.node
              putVar ref { node: node', vtree: vtree', state: s'', memo: memo', renderPending: false }
