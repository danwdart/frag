module Game where

import           BSP
import           Camera
import           Collision
import           Data.List
import           FRP.Yampa
import           IdentityList
import           Matrix
import           Object
import           Parser
import           Raybox
import           Visibility   (aiVisTest)

game :: BSPMap -> [ILKey -> Object] -> SF GameInput [ObsObjState]
game bspmap objs
  = loop
       (game'
          (listToILA objs)
          bspmap
          >>> arr (\ oos -> (oos, oos)))
       >>>
       arr (map ooObsObjState . elemsIL)

game' ::
      IL Object -> BSPMap -> SF (GameInput, IL ObjOutput) (IL ObjOutput)
game' objs bspmap
  = dpSwitch (route bspmap) objs (noEvent --> arr killOrSpawn)
      (\ sfs' f -> game' (f sfs') bspmap)

route ::
      BSPMap -> (GameInput, IL ObjOutput) -> IL sf -> IL (ObjInput, sf)
route bspmap (gi, oos) = mapIL routeAux
  where routeAux (k, obj)
          = case find (\ (x, _, _) -> k == x) states of
                Just (_, _, z) -> (z, obj)
                Nothing -> (ObjInput{oiHit = noEvent, oiMessage = noEvent,
                                     oiCollisionPos = (0, 0, 0), oiCollision = dummy,
                                     oiOnLand = False, oiVisibleObjs = noEvent, oiGameInput = gi},
                            obj)
        messages
          = concatMap eventToList $ elemsIL $ fmap ooSendMessage oos
        states
          = clips bspmap gi (assocsIL $ fmap ooObsObjState oos)
               (assocsIL $ fmap ooObsObjState oos)
              messages
        dummy = initCamera (80::Int, 611::Int, 60::Int) (80::Int, 611::Int, 59::Int) (0::Int, 1::Int, 0::Int)

killOrSpawn :: (a, IL ObjOutput) -> Event (IL Object -> IL Object)
killOrSpawn (_, oos)
  = foldl (mergeBy (.)) noEvent es
  where
        es :: [Event (IL Object -> IL Object)]
        es
          =    [mergeBy (.) (ooKillReq oo `tag` deleteIL k)
                  (fmap (foldl (.) id . map insertILA_) (ooSpawnReq oo))
                | (k, oo) <- assocsIL oos]

clips ::
      BSPMap ->
        GameInput ->
          [(ILKey, ObsObjState)] ->
            [(ILKey, ObsObjState)] ->
              [(ILKey, (ILKey, Message))] -> [(ILKey, ObsObjState, ObjInput)]
clips _ _ [] _ _ = []
clips mp gi ((k, oos) : kooss) ooses msgs
  = let x = clip mp gi oos ooses k msgs
        xs = clips mp gi kooss ooses msgs
    in (k, oos, x) : xs

clip :: BSPMap -> GameInput -> ObsObjState -> [(ILKey, ObsObjState)] ->
       ILKey -> [(ILKey, (ILKey, Message))] -> ObjInput
clip mp gi cam@OOSCamera{newCam = cam1, oldCam = cam2} ooses k msgs
  = let (camera, grounded) = clipCamera mp cam1 cam2 in
      ObjInput{oiHit = listToEvent $ findCollidingObjects ooses (k, cam),
               oiMessage = findMessages k msgs, oiCollisionPos = (0, 0, 0),
               oiCollision = camera, oiOnLand = grounded, oiVisibleObjs = noEvent,
               oiGameInput = gi}
clip mp gi
  acube@OOSAICube{oosNewCubePos = pos1, oosOldCubePos = pos2,
                  oosCubeSize = sz, health = h, target = t}
  ooses k msgs
  = let (clippedPos, grounded) = clipObject mp pos1 pos2 sz in
      ObjInput{oiHit =
                 listToEvent $ findCollidingObjects ooses (k, acube),
               oiCollision = initCamera (80::Int, 611, 60) (80::Int, 611, 59) (0, 1, 0),
               oiMessage = findMessages k msgs, oiCollisionPos = clippedPos,
               oiOnLand = grounded,
               oiVisibleObjs =
                 let value = if h == 100 && t == (0, 0, 0)
                             then 600
                             else 1800
                 in listToEvent $ findVisibleTargets mp ooses (k, acube) value,
               oiGameInput = gi}
clip mp gi
  OOSRay{rayStart = pos1, rayEnd = pos2, rayUC = pos3, clipped = ff}
  _ k msgs
  | not ff =
    let (_, hasCol) = clipRay mp pos3 pos1 (0, 0, 0) in
      ObjInput{oiHit = noEvent, oiMessage = findMessages k msgs,
               oiCollision = dummy, oiCollisionPos = fix hasCol pos2 pos3 pos1,
               oiOnLand = hasCol, oiVisibleObjs = noEvent, oiGameInput = gi}
  | otherwise =
    ObjInput{oiHit = noEvent, oiMessage = findMessages k msgs,
             oiCollision = dummy, oiCollisionPos = pos2, oiOnLand = True,
             oiVisibleObjs = noEvent, oiGameInput = gi}
  where fix clpped p2 p3 p1
          | clpped    = tryAccurate mp 4 p2 p3 p1
          | otherwise = pos3
        dummy = initCamera (80::Int, 611, 60) (80::Int, 611, 59) (0, 1, 0)
clip mp gi
  projectile@OOSProjectile{projectileNewPos = pos3,
                           projectileOldPos = pos1}
  ooses k _
  = let (clippedPos, hasCol) = clipRay mp pos3 pos1 (0, 0, 0) in
      ObjInput{oiHit =
                 listToEvent $ findCollidingObjects ooses (k, projectile),
               oiMessage = noEvent,
               oiCollision = initCamera (80::Int, 611, 60) (80::Int, 611, 59) (0, 1, 0),
               oiCollisionPos = clippedPos, oiOnLand = hasCol,
               oiVisibleObjs = noEvent, oiGameInput = gi}

listToEvent :: [a] -> Event [a]
listToEvent []   = noEvent
listToEvent list = Event list

eventToList :: Event [a] -> [a]
eventToList ev
  | isEvent ev = fromEvent ev
  | otherwise = []

tryAccurate :: BSPMap -> Int -> Vec3 -> Vec3 -> Vec3 -> Vec3
tryAccurate mp n dv1 dv2 vec
  | n == 0 = middle dv1 dv2 vec
  | snd (clipRay mp (middle dv1 dv2 vec) vec (0, 0, 0)) =
    tryAccurate mp (n - 1) dv1 (middle dv1 dv2 vec) vec
  | otherwise = tryAccurate mp (n - 1) (middle dv1 dv2 vec) dv2 vec
  where middle v1 v2 _ = vectorAdd v1 (vectorMult (vectorSub v2 v1) 0.5)

findCollidingObjects ::
                     [(ILKey, ObsObjState)] ->
                       (ILKey, ObsObjState) -> [(ILKey, ObsObjState)]
findCollidingObjects ooses (k, obj)
  | isProjectile obj =
    [(k', oos') | (k', oos') <- ooses, k /= k', isCamera oos',
     checkCollision obj oos']
  | isCamera obj =
    [(k', oos') | (k', oos') <- ooses, k /= k', isProjectile oos',
     checkCollision obj oos']
  | isAICube obj =
    [(k', oos') | (k', oos') <- ooses, k /= k', isRay oos',
     checkCollision obj oos']

checkCollision :: ObsObjState -> ObsObjState -> Bool
checkCollision obj1 obj2
  | isCamera obj2 && isProjectile obj1 =
    pointBox (cpos (oldCam obj2)) (projectileOldPos obj1)
      (20, 50, 20)
  | isCamera obj1 && isProjectile obj2 =
    pointBox (cpos (oldCam obj1)) (projectileOldPos obj2)
      (20, 50, 20)
  | isAICube obj1 && isRay obj2 =
    let (x, y, z) = oosOldCubePos obj1
        (cx, cy, cz) = oosCubeSize obj1
      in
      rayBox (rayStart obj2) (rayEnd obj2) (x - cx, y - cy, z - cz)
        (x + cx, y + cy, z + cz)
checkCollision _ _ = False

findVisibleTargets ::
                   BSPMap ->
                     [(ILKey, ObsObjState)] ->
                       (ILKey, ObsObjState) -> Int -> [(ILKey, ObsObjState)]
findVisibleTargets bsp ooses (k, obj) range
  | isAICube obj =
    [(k', oos') | (k', oos') <- ooses, k /= k', isCamera oos',
     checkVisible bsp obj oos' range]
  | otherwise = []

checkVisible :: BSPMap -> ObsObjState -> ObsObjState -> Int -> Bool
checkVisible bsp obj1 obj2 range
  | isAICube obj1 && isCamera obj2 =
    let (x, y, z) = oosOldCubePos obj1
        (cx, cy, cz) = cpos (oldCam obj2)
      in aiVisTest bsp (x, y, z) (oosCubeAngle obj1) (cx, cy, cz) range
checkVisible _ _ _ _ = True

findMessages ::
             ILKey -> [(ILKey, (ILKey, Message))] -> Event [(ILKey, Message)]
findMessages key messages
  = listToEvent $
      map snd (filter (\ (destkey, _) -> destkey == key) messages)
