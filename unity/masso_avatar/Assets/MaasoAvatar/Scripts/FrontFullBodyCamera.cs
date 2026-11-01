using System.Collections.Generic;
using Maaso.World;
using UnityEngine;

namespace Maaso.Avatar
{
    [DisallowMultipleComponent]
    [ExecuteAlways]
    [DefaultExecutionOrder(12000)]
    [RequireComponent(typeof(Camera))]
    public sealed class FrontFullBodyCamera : MonoBehaviour
    {
        private const float HumanoidHorizontalPadding = 0.22f;
        private const float HumanoidTopPadding = 0.35f;
        private const float HumanoidBottomPadding = 0.08f;
        private const float HumanoidDepthPadding = 0.16f;
        private const string ManualAvatarMotionMode = "manual_avatar_motion";
        private const float FramingTransitionSeconds = 0.6f;
        // The rear bookcase reaches z=3.55; keep Home in front of its geometry.
        private const float HomeRoomCameraDistance = 3.2f;

        private static readonly HumanBodyBones[] FramingBones =
        {
            HumanBodyBones.Hips,
            HumanBodyBones.Spine,
            HumanBodyBones.Chest,
            HumanBodyBones.UpperChest,
            HumanBodyBones.Neck,
            HumanBodyBones.Head,
            HumanBodyBones.LeftShoulder,
            HumanBodyBones.LeftUpperArm,
            HumanBodyBones.LeftLowerArm,
            HumanBodyBones.LeftHand,
            HumanBodyBones.RightShoulder,
            HumanBodyBones.RightUpperArm,
            HumanBodyBones.RightLowerArm,
            HumanBodyBones.RightHand,
            HumanBodyBones.LeftUpperLeg,
            HumanBodyBones.LeftLowerLeg,
            HumanBodyBones.LeftFoot,
            HumanBodyBones.LeftToes,
            HumanBodyBones.RightUpperLeg,
            HumanBodyBones.RightLowerLeg,
            HumanBodyBones.RightFoot,
            HumanBodyBones.RightToes,
        };

        [SerializeField] private Transform targetRoot;
        [SerializeField] private bool autoFindTarget = true;
        [SerializeField, Min(1f)] private float framingPadding = 1f;
        [SerializeField, Min(0.1f)] private float minDistance = 0.25f;
        [SerializeField, Range(0f, 0.45f)] private float topSafeViewport = 0.15f;
        [SerializeField, Range(0f, 0.45f)] private float bottomSafeViewport = 0.2f;
        [SerializeField] private bool autoFrameEnabled = true;

        private Camera targetCamera;
        private readonly List<Renderer> renderers = new();
        private Transform cachedBoundsRoot;
        private Bounds cachedLocalBounds;
        private bool hasCachedLocalBounds;
        private Transform cachedStandingInteriorRoot, cachedStandingInteriorReference;
        private string cachedStandingInteriorMode;
        private Bounds cachedStandingInteriorLocalBounds;
        private bool hasCachedStandingInteriorBounds;
        private float visibleBodyRatio = 1f;
        private bool hasFramedPose;
        private bool transitionActive;
        private float transitionElapsed;
        private CameraPose transitionOrigin;
        private float transitionOriginFieldOfView;
        private Transform homeViewReference;
        private PersistentWorldMapController homeMap;
        private Transform cachedHomeEnvironmentRoot;
        private readonly List<Renderer> homeEnvironmentRenderers = new();
        private Vector3 stableHomeFront;
        private Vector3 stableHomeUp;
        private bool hasStableHomeView;
        private float authoredHomeFieldOfView;
        public Vector2 ViewportSafeArea => new(topSafeViewport, bottomSafeViewport);
        private bool hasAuthoredHomeFieldOfView;
        private bool homeFieldOfViewAdjusted;

        private LoginDoorwayRig entrySafetyRig;
        private Transform entrySafetyParent;
        private string entrySafetyRevision;
        private Transform entryRoutedAvatar;
        private Transform doorwayHandoffAvatar;
        private Vector3 doorwayHandoffAvatarPosition;
        private string doorwayHandoffMode;
        private bool presenceProjectionHeld;
        private Transform presenceProjectionAvatar, presenceProjectionSceneParent;
        private LoginDoorwayRig presenceProjectionRig;
        private string presenceProjectionMode, presenceProjectionRevision;
        private float presenceProjectionAspect, presenceProjectionTop, presenceProjectionBottom;
        private Rect presenceProjectionRect;
        private List<Vector3> homeInteriorPath;
        private int homeInteriorWaypoint;
        private Vector3 homeInteriorGoal;
        private Transform deskTravelRoot;
        private float deskTravelLastRealtime = -1f;
        private bool deskTravelActive, deskTravelRecovering, deskDiagnosticPending, deskDiagnosticBlocked;
        private bool hasDeskTravelGoal;
        private bool hasDeskRecoveryDirection;
        private Vector3 deskRecoveryDirection;
        private CameraPose deskTravelGoal;
        private float deskTravelGoalFieldOfView;
        public void BindEntrySafety(LoginDoorwayRig rig)
        {
            if(entrySafetyRig==rig&&rig!=null&&rig.IsSceneEntryBound&&entrySafetyParent==rig.SceneEntry.SceneRoot.parent&&entrySafetyRevision==rig.SceneEntry.SceneRevision)return;
            entrySafetyRig=rig != null && rig.IsSceneEntryBound ? rig : null;
            entrySafetyParent=entrySafetyRig != null ? entrySafetyRig.SceneEntry.SceneRoot.parent : null;
            entrySafetyRevision=entrySafetyRig != null ? entrySafetyRig.SceneEntry.SceneRevision : null;
            entryRoutedAvatar=null;
            doorwayHandoffAvatar=null;
            homeInteriorPath=null;
        }
        public void CompleteDoorwayCameraRoute(LoginDoorwayRig rig)
        {
            if(entrySafetyRig!=rig||targetRoot==null||rig?.Navigation==null||!rig.Navigation.ContainsCamera(transform.position))return;
            presenceProjectionHeld = false;
            entryRoutedAvatar=targetRoot;
            doorwayHandoffAvatar=targetRoot;
            doorwayHandoffAvatarPosition=targetRoot.position;
            doorwayHandoffMode=FramingMode;
        }

        public bool CompletePresenceCameraRoute(Transform avatar)
        {
            // Presence has already delivered this Home projection. OnEnable
            // must not snap to fresh idle-bone bounds on the arrival frame.
            // Reuse the doorway's fenced handoff; other camera owners, rooms,
            // targets and manual compositions cannot acquire that hold.
            if (avatar == null || targetRoot != avatar || homeMap == null ||
                !autoFrameEnabled || entrySafetyRig == null ||
                !entrySafetyRig.IsSceneEntryBound || entrySafetyRig.Navigation == null ||
                entrySafetyRig.SceneEntry.SceneRoot.parent != entrySafetyParent ||
                entrySafetyRig.SceneEntry.SceneRevision != entrySafetyRevision ||
                homeMap.PersistentEnvironmentRoot == null ||
                (entrySafetyRig.SceneEntry.SceneRoot != homeMap.PersistentEnvironmentRoot &&
                 !entrySafetyRig.SceneEntry.SceneRoot.IsChildOf(homeMap.PersistentEnvironmentRoot)) ||
                GetComponent<WorldCameraDirector>()?.OwnsCamera == true ||
                !HasVisibleHomeRoom() || !entrySafetyRig.Navigation.ContainsCamera(transform.position))
                return false;
            CompleteDoorwayCameraRoute(entrySafetyRig);
            presenceProjectionHeld = doorwayHandoffAvatar == avatar;
            if (!presenceProjectionHeld) return false;
            presenceProjectionAvatar = avatar;
            presenceProjectionMode = FramingMode;
            presenceProjectionRig = entrySafetyRig;
            presenceProjectionSceneParent = entrySafetyParent;
            presenceProjectionRevision = entrySafetyRevision;
            Camera view = GetComponent<Camera>();
            presenceProjectionAspect = view.aspect;
            presenceProjectionRect = view.rect;
            presenceProjectionTop = topSafeViewport;
            presenceProjectionBottom = bottomSafeViewport;
            return true;
        }

        // Returning from the local room has delivered the same grounded Home
        // image as Presence. Share its model/room/viewport fences so OnEnable
        // preserves that final image and a later resize releases it normally.
        public bool CompleteSpaceReturnCameraRoute(Transform avatar) => CompletePresenceCameraRoute(avatar);

        internal void ReleasePresenceCameraRoute()
        {
            if (!presenceProjectionHeld) return;
            if (doorwayHandoffAvatar == presenceProjectionAvatar && doorwayHandoffMode == presenceProjectionMode)
                doorwayHandoffAvatar = null;
            presenceProjectionHeld = false;
        }

        private void ValidatePresenceCameraRoute()
        {
            if (!presenceProjectionHeld) return;
            // A different route has already replaced this handoff. Its camera
            // belongs to that route, so discard only the old Presence marker.
            if (doorwayHandoffAvatar != presenceProjectionAvatar || doorwayHandoffMode != presenceProjectionMode)
            {
                presenceProjectionHeld = false;
                return;
            }
            Camera view = GetComponent<Camera>();
            Rect viewport = view.rect;
            bool viewportChanged = !Mathf.Approximately(view.aspect, presenceProjectionAspect) ||
                !Mathf.Approximately(viewport.x, presenceProjectionRect.x) ||
                !Mathf.Approximately(viewport.y, presenceProjectionRect.y) ||
                !Mathf.Approximately(viewport.width, presenceProjectionRect.width) ||
                !Mathf.Approximately(viewport.height, presenceProjectionRect.height) ||
                !Mathf.Approximately(topSafeViewport, presenceProjectionTop) ||
                !Mathf.Approximately(bottomSafeViewport, presenceProjectionBottom);
            if (viewportChanged || !autoFrameEnabled || homeMap == null || !HasVisibleHomeRoom() ||
                targetRoot != presenceProjectionAvatar || FramingMode != presenceProjectionMode ||
                entrySafetyRig != presenceProjectionRig || entrySafetyRig == null || !entrySafetyRig.IsSceneEntryBound ||
                entrySafetyRig.SceneEntry.SceneRoot.parent != presenceProjectionSceneParent ||
                entrySafetyRig.SceneEntry.SceneRevision != presenceProjectionRevision ||
                GetComponent<WorldCameraDirector>()?.OwnsCamera == true)
                ReleasePresenceCameraRoute();
        }

        private bool HoldDoorwayCamera()
        {
            if(doorwayHandoffAvatar==null)return false;
            if(targetRoot!=doorwayHandoffAvatar||FramingMode!=doorwayHandoffMode||
                Vector3.Distance(targetRoot.position,doorwayHandoffAvatarPosition)>.15f||
                entrySafetyRig==null||!entrySafetyRig.IsSceneEntryBound||entrySafetyRig.SceneEntry.SceneRevision!=entrySafetyRevision||
                GetComponent<WorldCameraDirector>()?.OwnsCamera==true)
            {doorwayHandoffAvatar=null;return false;}
            // The doorway has already delivered the exact Home shot. An idle
            // animation, safe-area message, or duplicate framing command must
            // not start another camera move after the handoff.
            return true;
        }
        private bool furniturePoseActive;
        private Transform deskWorkSurface, deskWorkSeat;
        public bool HasDeskWorkAnchor => deskWorkSurface!=null && deskWorkSeat!=null;
        public void SetDeskWorkAnchor(AvatarFurnitureAnchor anchor)
        {
            deskWorkSurface=anchor?.WorkSurface;deskWorkSeat=anchor?.Seat;
        }
        public void SetFurniturePoseActive(bool active)
        {
            if (furniturePoseActive == active) return;
            furniturePoseActive = active; hasCachedLocalBounds = false;
            hasCachedStandingInteriorBounds = false;
        }
        public string FramingMode { get; private set; } = "hero_full_body";
        public float VisibleBodyRatio => visibleBodyRatio;
        public bool IsTransitioningToDefaultFullBody => transitionActive &&
            (FramingMode is "hero_full_body" or "full" or "front_full_body");
        public bool IsFramingTransitionActive => transitionActive;

        public Transform TargetRoot
        {
            get => targetRoot;
            set
            {
                targetRoot = value;
                hasCachedLocalBounds = false;
                cachedBoundsRoot = null;
                hasCachedStandingInteriorBounds = false;
                cachedStandingInteriorRoot = null;
                hasFramedPose = false;
                transitionActive = false;
                homeInteriorPath=null;
                doorwayHandoffAvatar=null;
                ResetDeskTravel();
            }
        }

        // The room owns the viewing direction; avatar turns only change its
        // pose. Rebinding a model or resuming framing must not orbit the room.
        public void SetHomeViewReference(Transform reference)
        {
            if (homeViewReference != reference) hasCachedStandingInteriorBounds = false;
            homeViewReference = reference;
            homeMap = reference != null
                ? reference.GetComponentInParent<PersistentWorldMapController>()
                : null;
            if (reference != null)
            {
                RememberHomeFieldOfView();
                stableHomeFront = -reference.forward;
                stableHomeUp = reference.up;
                hasStableHomeView = true;
                if(homeMap!=null)BindEntrySafety(LoginDoorwayRig.Ensure(homeMap));
            }
            else
            {
                RestoreHomeFieldOfView();
                hasAuthoredHomeFieldOfView = false;
            }
        }

        public void SetFramingMode(string mode)
        {
            bool deskRequest = (mode ?? string.Empty).Trim().Replace('-', '_').Equals("desk_over_shoulder", System.StringComparison.OrdinalIgnoreCase);
            bool recoveryRequest = FramingMode == "desk_over_shoulder" && !deskRequest;
            SetFramingModeCore(mode, Application.isPlaying);
            if (deskRequest || recoveryRequest)
            {
                deskDiagnosticPending = true;
                deskDiagnosticBlocked = false;
                LogDeskCamera("requested", mode, Time.unscaledDeltaTime);
            }
        }

        private void SetFramingModeCore(string mode, bool smooth)
        {
            string normalized = string.IsNullOrWhiteSpace(mode)
                ? string.Empty
                : mode.Trim().ToLowerInvariant().Replace("-", "_").Replace(" ", "_");

            normalized = string.IsNullOrEmpty(normalized) ? "hero_full_body" : normalized;
            if (normalized == FramingMode && autoFrameEnabled)
            {
                if (normalized == "desk_over_shoulder" && (!deskTravelActive || deskTravelRoot != targetRoot) &&
                    targetRoot != null && furniturePoseActive && HasDeskWorkAnchor &&
                    GetComponent<WorldCameraDirector>()?.OwnsCamera != true)
                {
                    deskTravelActive = true; deskTravelRecovering = false;
                    deskTravelRoot = targetRoot; deskTravelLastRealtime = -1f; hasDeskTravelGoal = false;
                    hasDeskRecoveryDirection = false;
                }
                if (!hasFramedPose && isActiveAndEnabled) FrameNow();
                return;
            }
            hasCachedStandingInteriorBounds = false;
            FramingMode = normalized;
            doorwayHandoffAvatar=null;
            if (normalized == "desk_over_shoulder")
            {
                deskTravelActive = true; deskTravelRecovering = false;
                deskTravelRoot = targetRoot; deskTravelLastRealtime = -1f; hasDeskTravelGoal = false;
            }
            else if (deskTravelActive && (normalized is "hero_full_body" or "upper_body" or "head"))
            {
                deskTravelRecovering = true; hasDeskTravelGoal = false; hasDeskRecoveryDirection = false;
            }
            else ResetDeskTravel();

            if (normalized == ManualAvatarMotionMode)
            {
                autoFrameEnabled = false;
                transitionActive = false;
                return;
            }

            autoFrameEnabled = true;
            if (normalized == "head")
            {
                visibleBodyRatio = 0.28f;
            }
            else if (normalized == "upper_body")
            {
                visibleBodyRatio = 0.5f;
            }
            else if (normalized == "three_quarter")
            {
                visibleBodyRatio = 0.76f;
            }
            else if (normalized == "full" ||
                normalized == "front_full_body" ||
                normalized == "hero_full_body")
            {
                visibleBodyRatio = 1f;
                framingPadding = 1f;
            }

            if (!isActiveAndEnabled)
            {
                transitionActive = false;
                return;
            }
            if (smooth && hasFramedPose)
            {
                transitionOrigin = new CameraPose(transform.position, transform.rotation);
                transitionOriginFieldOfView = GetComponent<Camera>().fieldOfView;
                transitionElapsed = 0f;
                transitionActive = true;
            }
            else
            {
                FrameNow();
            }
        }

        public void SetViewportSafeArea(float top, float bottom)
        {
            topSafeViewport = Mathf.Clamp(float.IsNaN(top) ? 0f : top, 0f, 0.45f);
            bottomSafeViewport = Mathf.Clamp(float.IsNaN(bottom) ? 0f : bottom, 0f, 0.45f);
            ValidatePresenceCameraRoute();
            if (!autoFrameEnabled || !isActiveAndEnabled)
            {
                return;
            }

            // Safe-area updates during a move change the destination, not the
            // in-flight camera pose. Repeated layout messages cannot snap it.
            if (!transitionActive) FrameNow();
        }

        public void FrameNow()
        {
            transitionActive = false;
            if(HoldDoorwayCamera())return;
            if(TryAdvanceHomeInterior(0,true))return;
            if (TryCalculateCurrentPose(out CameraPose pose, out float fieldOfView))
            {
                transform.SetPositionAndRotation(pose.Position, pose.Rotation);
                ApplyFieldOfView(fieldOfView);
                hasFramedPose = true;
            }
            else RestoreHomeFieldOfView();
        }

        // A world camera can resolve the eventual Home shot without applying
        // that shot to the camera it currently owns.
        public bool TryGetHomeFramingPose(out CameraPose pose, out float fieldOfView) =>
            TryCalculateCurrentPose(out pose, out fieldOfView);

        // Input focus is a temporary Home closeup. A private-room entry can
        // resolve the ordinary full-body Home destination without applying a
        // mode, moving the lens, or changing the selected actor's live image.
        public bool TryGetDefaultHomeFullBodyFramingPose(Transform avatar,LoginDoorwayRig rig,
            out CameraPose pose,out float fieldOfView)
        {
            pose=default;fieldOfView=0;
            if(avatar==null || targetRoot!=avatar || rig?.Navigation==null)return false;
            Vector3 front=hasStableHomeView?stableHomeFront:rig.Navigation.transform.forward;
            float previousPadding=framingPadding;
            try
            {
                framingPadding=1f;
                return TryGetInteriorOwnedFramingPose(avatar,"hero_full_body",rig,front,false,
                    out pose,out fieldOfView,out _,true);
            }
            finally {framingPadding=previousPadding;}
        }

        public bool TryGetDoorwayFramingPose(LoginDoorwayRig rig,out CameraPose pose,out float fieldOfView)
        {
            if(rig?.Navigation!=null&&targetRoot!=null)
            {
                Vector3 front=FramingMode is "upper_body" or "head"?targetRoot.forward:hasStableHomeView?stableHomeFront:rig.Navigation.transform.forward;
                return TryGetInteriorOwnedFramingPose(targetRoot,FramingMode,rig,front,false,out pose,out fieldOfView,out _,true);
            }
            if(!TryCalculateCurrentPose(out pose,out fieldOfView,false,true))return false;
            return true;
        }
        public Vector3 DoorwaySubjectFocus => targetRoot!=null&&TryGetTargetBounds(targetRoot,renderers,out Bounds bounds,true)?bounds.center:targetRoot!=null?targetRoot.position:Vector3.zero;
        public bool TryGetWorldOwnedFramingPose(Transform avatar,string mode,LoginDoorwayRig rig,Vector3 front,out CameraPose pose,out float fieldOfView,out Bounds subjectBounds)
            =>TryGetInteriorOwnedFramingPose(avatar,mode,rig,front,true,out pose,out fieldOfView,out subjectBounds);
        private bool TryGetInteriorOwnedFramingPose(Transform avatar,string mode,LoginDoorwayRig rig,Vector3 front,bool worldOwned,out CameraPose pose,out float fieldOfView,out Bounds subjectBounds,bool allowDisabled=false)
        {
            pose=default;fieldOfView=worldOwned?51:hasAuthoredHomeFieldOfView?authoredHomeFieldOfView:60;subjectBounds=default;
            if((worldOwned?enabled:!isActiveAndEnabled&&!allowDisabled)||avatar==null||rig?.Navigation==null||mode is not ("hero_full_body" or "upper_body" or "sleeping_top" or "head" or "three_quarter" or "full" or "front_full_body" or "desk_over_shoulder"))return false;
            // This shot belongs to a confirmed Home task. World/capture
            // never inherit it when they take the shared camera.
            if(mode=="desk_over_shoulder" && (worldOwned || !HasDeskWorkAnchor))return false;
            targetCamera=targetCamera!=null?targetCamera:GetComponent<Camera>();if(targetCamera==null)return false;
            var previousTarget=targetRoot;string previousMode=FramingMode;float previousRatio=visibleBodyRatio;bool previousFurniture=furniturePoseActive;
            var previousReference=homeViewReference;Vector3 previousFront=stableHomeFront,previousUp=stableHomeUp;bool previousStable=hasStableHomeView;
            bool standingHome=!worldOwned&&!previousFurniture&&avatar==previousTarget&&
                (mode is "hero_full_body" or "full" or "front_full_body" or "three_quarter");
            try
            {
                targetRoot=avatar;FramingMode=mode;visibleBodyRatio=mode=="upper_body" ? .5f : mode=="head" ? .28f : mode=="three_quarter" ? .76f : 1;furniturePoseActive=true;
                // Local doorway handoff is the same Home composition. Keep
                // its authored camera-depth limit while calculating the final
                // full-body pose; otherwise a taller avatar can push the
                // destination behind the living-room bookcase.
                bool homeFullBody=!worldOwned&&previousReference!=null&&
                    (mode is "hero_full_body" or "full" or "front_full_body");
                homeViewReference=homeFullBody?previousReference:null;
                stableHomeFront=front;stableHomeUp=Vector3.up;hasStableHomeView=true;
                bool useStandingCache=standingHome&&hasCachedStandingInteriorBounds&&
                    cachedStandingInteriorRoot==avatar&&cachedStandingInteriorMode==mode&&
                    cachedStandingInteriorReference==previousReference;
                Bounds bounds;
                if(useStandingCache)bounds=TransformBounds(avatar,cachedStandingInteriorLocalBounds);
                else if(!TryGetTargetBounds(avatar,renderers,out bounds,true))return false;
                subjectBounds=bounds;
                if(mode!="sleeping_top")subjectBounds.size=new Vector3(Mathf.Min(.56f,bounds.size.x),bounds.size.y,Mathf.Min(.56f,bounds.size.z));
                // Pure pose calculation only. The World camera retains the
                // enabled component, transform, lens and transition ownership.
                pose=CalculateFramedPose(bounds,homeFullBody,Matrix4x4.identity,ref fieldOfView);
                bool fits=TryFitDoorwayPose(rig,ref pose,ref fieldOfView,true,standingHome?bounds:(Bounds?)null);
                if(fits&&standingHome&&!useStandingCache)
                {
                    // Preserve the first solved Humanoid composition. The
                    // ordinary visual cache also serves Home return and must
                    // not silently change its bounds source to achieve this.
                    cachedStandingInteriorLocalBounds=InverseTransformBounds(avatar,bounds);
                    cachedStandingInteriorRoot=avatar;cachedStandingInteriorMode=mode;
                    cachedStandingInteriorReference=previousReference;hasCachedStandingInteriorBounds=true;
                }
                return fits;
            }
            finally{targetRoot=previousTarget;FramingMode=previousMode;visibleBodyRatio=previousRatio;furniturePoseActive=previousFurniture;homeViewReference=previousReference;stableHomeFront=previousFront;stableHomeUp=previousUp;hasStableHomeView=previousStable;}
        }
        private bool TryFitDoorwayPose(LoginDoorwayRig rig,ref CameraPose pose,ref float fieldOfView,bool allowOrbit=false,Bounds? focusBounds=null)
        {
            Vector3 forward=pose.Rotation*Vector3.forward;
            Bounds bounds;
            if(focusBounds.HasValue)bounds=focusBounds.Value;
            else if(!TryGetTargetBounds(targetRoot,renderers,out bounds,true))return false;
            float distance=Mathf.Max(.35f,Vector3.Dot(bounds.center-pose.Position,forward));
            Vector3 focus=pose.Position+forward*distance;
            CameraPose fitted;float fittedFov;
            bool fits=allowOrbit?rig.TryFitWorldCameraDestination(pose,fieldOfView,focus,out fitted,out fittedFov):rig.TryFitCameraDestination(pose,fieldOfView,focus,out fitted,out fittedFov);
            if(!fits)return false;
            pose=fitted;fieldOfView=fittedFov;return true;
        }

        public bool TryGetHomeReturnFramingPose(Transform homeAnchor,
            out CameraPose pose, out float fieldOfView)
        {
            pose = default;
            fieldOfView = 0f;
            targetCamera = targetCamera != null ? targetCamera : GetComponent<Camera>();
            if (enabled || !autoFrameEnabled || targetRoot == null ||
                targetCamera == null || targetCamera.orthographic || homeMap == null ||
                homeAnchor == null || homeMap.HomeAgentAnchor != homeAnchor ||
                homeViewReference == null || homeMap.HomeCameraReference != homeViewReference ||
                !hasAuthoredHomeFieldOfView ||
                (targetCamera.clearFlags != CameraClearFlags.Skybox && targetCamera.backgroundColor.a < 0.99f))
                return false;
            targetRoot.GetComponentsInChildren(false, renderers);
            if (!HasCameraLayerGeometry(renderers)) return false;
            Transform environment = homeMap.PersistentEnvironmentRoot;
            if (environment == null) return false;
            environment.GetComponentsInChildren(true, homeEnvironmentRenderers);
            // The known Home environment can be inactive while a micro-world
            // is presented. Its layer must still belong to this Home camera.
            bool hasHomeGeometry = false;
            foreach (Renderer renderer in homeEnvironmentRenderers)
                if (renderer != null && (targetCamera.cullingMask & (1 << renderer.gameObject.layer)) != 0)
                { hasHomeGeometry = true; break; }
            if (!hasHomeGeometry || !hasCachedLocalBounds || cachedBoundsRoot != targetRoot) return false;

            // World ownership reparents this same target before the camera
            // enters. Predict its anchored, grounded Home transform without
            // moving a live mesh, changing its flags, or applying the camera.
            Matrix4x4 homeMatrix = Matrix4x4.TRS(homeAnchor.position, homeAnchor.rotation, targetRoot.lossyScale);
            Bounds bounds = TransformBoundsCorners(cachedLocalBounds, homeMatrix);
            float groundOffset = PersistentWorldMapController.GroundY - WorldAvatarGrounding.GroundContactInset - bounds.min.y;
            homeMatrix.m13 += groundOffset;
            bounds.center += Vector3.up * groundOffset;
            Matrix4x4 worldToHome = homeMatrix * targetRoot.worldToLocalMatrix;
            fieldOfView = authoredHomeFieldOfView;
            pose = CalculateFramedPose(bounds, visibleBodyRatio >= 0.999f, worldToHome, ref fieldOfView);
            return true;
        }

        public void AdvanceFraming(float unscaledDeltaTime)
        {
            if (!autoFrameEnabled || !isActiveAndEnabled)
            {
                return;
            }
            if(HoldDoorwayCamera())return;
            if(TryAdvanceHomeInterior(unscaledDeltaTime,false))return;
            if (!TryCalculateCurrentPose(out CameraPose pose, out float fieldOfView))
            {
                RestoreHomeFieldOfView();
                return;
            }
            if (transitionActive && hasFramedPose)
            {
                float step = float.IsNaN(unscaledDeltaTime) || float.IsInfinity(unscaledDeltaTime)
                    ? 0f : Mathf.Max(0f, unscaledDeltaTime);
                transitionElapsed = Mathf.Min(FramingTransitionSeconds, transitionElapsed + step);
                float eased = Mathf.SmoothStep(0f, 1f, transitionElapsed / FramingTransitionSeconds);
                transform.SetPositionAndRotation(
                    Vector3.Lerp(transitionOrigin.Position, pose.Position, eased),
                    Quaternion.Slerp(transitionOrigin.Rotation, pose.Rotation, eased));
                ApplyFieldOfView(Mathf.Lerp(transitionOriginFieldOfView, fieldOfView, eased));
                transitionActive = transitionElapsed < FramingTransitionSeconds;
            }
            else
            {
                transform.SetPositionAndRotation(pose.Position, pose.Rotation);
                ApplyFieldOfView(fieldOfView);
            }
            hasFramedPose = true;
        }

        private bool TryAdvanceHomeInterior(float delta,bool immediateIfSafe)
        {
            if(!isActiveAndEnabled||!autoFrameEnabled||targetRoot==null||homeMap==null||entrySafetyRig==null||
                !entrySafetyRig.IsSceneEntryBound||entrySafetyRig.SceneEntry.SceneRoot.parent!=entrySafetyParent||entrySafetyRig.SceneEntry.SceneRevision!=entrySafetyRevision||entrySafetyRig.Navigation==null)return false;
            if(GetComponent<WorldCameraDirector>()?.OwnsCamera==true)return true;
            var nav=entrySafetyRig.Navigation;
            Vector3 front=FramingMode is "upper_body" or "head"?targetRoot.forward:hasStableHomeView?stableHomeFront:nav.transform.forward;
            CameraPose destination; float fov; Bounds subject;
            bool solved = deskTravelRecovering && !furniturePoseActive
                ? TryGetDeskRecoveryPose(nav, out destination, out fov, out subject)
                : TryGetInteriorOwnedFramingPose(targetRoot,FramingMode,entrySafetyRig,front,false,out destination,out fov,out subject);
            if(!solved)
            { LogDeskBlocked("solver_blocked", delta); return true; }
            if (deskTravelActive)
            {
                deskTravelGoal = destination; deskTravelGoalFieldOfView = fov; hasDeskTravelGoal = true;
            }
            targetCamera=targetCamera!=null?targetCamera:GetComponent<Camera>();if(targetCamera==null)return true;
            if(!nav.ContainsCamera(transform.position))
            {
                // Presence can restore an older camera pose. A remembered frame
                // cannot keep an outside-room camera after Home regains ownership.
                CameraPose recovery = entrySafetyRig.LobbyPose;
                if(!nav.ContainsCamera(recovery.Position))return true;
                transform.SetPositionAndRotation(recovery.Position,recovery.Rotation);
                homeInteriorPath=null;
                homeInteriorWaypoint=0;
            }
            transitionActive=false;
            if(immediateIfSafe&&nav.CameraSegmentAvoidsSubject(transform.position,destination.Position,subject)&&
                !nav.CrossesBedroomPortal(transform.position,new[]{destination.Position}))
            {
                transform.SetPositionAndRotation(destination.Position,destination.Rotation);ApplyFieldOfView(fov);homeInteriorPath=null;hasFramedPose=true;return true;
            }
            if(homeInteriorPath==null||Vector3.Distance(homeInteriorGoal,destination.Position)>.15f)
            {
                if(!nav.TryBuildCameraRouteAroundSubject(transform.position,destination.Position,subject,out homeInteriorPath) &&
                    !(deskTravelActive && TryBuildDeskSubjectEscapeRoute(nav, transform.position, destination.Position, subject, out homeInteriorPath)))
                { homeInteriorPath=null; LogDeskBlocked("route_blocked", delta, subject); return true; }
                homeInteriorGoal=destination.Position;homeInteriorWaypoint=0;
            }
            if(homeInteriorWaypoint<homeInteriorPath.Count)
            {
                Vector3 point=homeInteriorPath[homeInteriorWaypoint];
                if(nav.CrossesBedroomPortal(transform.position,new[]{point}))
                {if(nav.BedroomDoor==null||!nav.BedroomDoor.RequestOpen()||!nav.BedroomDoor.IsOpen)return true;}
                float step=Mathf.Clamp(float.IsNaN(delta)||float.IsInfinity(delta)?0:delta,0,.1f);
                Vector3 next=Vector3.MoveTowards(transform.position,point,step*1.4f);
                if(!nav.CameraSegmentAvoidsSubject(transform.position,next,subject)){homeInteriorPath=null;return true;}
                transform.position=next;if(Vector3.Distance(next,point)<.002f)homeInteriorWaypoint++;
            }
            Vector3 forward=destination.Rotation*Vector3.forward;
            Vector3 focus=destination.Position+forward*Mathf.Max(.3f,Vector3.Dot(subject.center-destination.Position,forward));
            Vector3 look=focus-transform.position;
            Quaternion orientation=look.sqrMagnitude>.001f?Quaternion.LookRotation(look,Mathf.Abs(Vector3.Dot(look.normalized,Vector3.up))>.96f?Vector3.back:Vector3.up):destination.Rotation;
            if(Vector3.Distance(transform.position,destination.Position)<.1f)orientation=destination.Rotation;
            float blend=1-Mathf.Exp(-Mathf.Clamp(delta,0,.1f)*5);
            transform.rotation=Quaternion.Slerp(transform.rotation,orientation,blend);ApplyFieldOfView(Mathf.Lerp(targetCamera.fieldOfView,fov,blend));
            hasFramedPose=true;return true;
        }

        // A newly seated or standing body can surround the old portrait camera.
        // Add only an outward first segment, retaining the room check and the
        // existing subject-clear route for every subsequent segment.
        private static bool TryBuildDeskSubjectEscapeRoute(PersonalSpaceNavigation navigation, Vector3 from,
            Vector3 destination, Bounds subject, out List<Vector3> route)
        {
            route = null;
            Bounds exclusion = subject; exclusion.Expand(.16f);
            if (!exclusion.Contains(from)) return false;
            float bestLength = float.PositiveInfinity;
            for (int index = 0; index < 16; index++)
            {
                float angle = index * Mathf.PI / 8f;
                Vector3 direction = new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle));
                float distance = float.PositiveInfinity;
                if (direction.x > .0001f) distance = Mathf.Min(distance, (exclusion.max.x - from.x) / direction.x);
                else if (direction.x < -.0001f) distance = Mathf.Min(distance, (exclusion.min.x - from.x) / direction.x);
                if (direction.z > .0001f) distance = Mathf.Min(distance, (exclusion.max.z - from.z) / direction.z);
                else if (direction.z < -.0001f) distance = Mathf.Min(distance, (exclusion.min.z - from.z) / direction.z);
                if (float.IsNaN(distance) || float.IsInfinity(distance) || distance < 0f || distance > 1.25f) continue;
                Vector3 escape = from + direction * (distance + .12f);
                if (exclusion.Contains(escape) || !navigation.CameraSegmentAvoidsSubject(from, escape, subject) ||
                    navigation.CrossesBedroomPortal(from, new[] { escape }) ||
                    !navigation.TryBuildCameraRouteAroundSubject(escape, destination, subject, out List<Vector3> continuation)) continue;
                float length = Vector3.Distance(from, escape);
                Vector3 previous = escape;
                foreach (Vector3 point in continuation) { length += Vector3.Distance(previous, point); previous = point; }
                if (length >= bestLength) continue;
                bestLength = length;
                route = new List<Vector3> { escape }; route.AddRange(continuation);
            }
            return route != null;
        }

        // A close portrait beside the desk can be inside the standing body's
        // exclusion volume. Recompose the real standing bones from the safe
        // desk side, widening the existing lens instead of orbiting into a wall.
        // This fallback belongs only to the just-finished task's return.
        private bool TryGetDeskRecoveryPose(PersonalSpaceNavigation navigation, out CameraPose pose, out float fov, out Bounds subject)
        {
            pose = default; fov = 58f; subject = default;
            if (targetRoot == null || !TryGetHumanoidBounds(targetRoot, out Bounds bounds)) return false;
            subject = bounds;
            subject.size = new Vector3(Mathf.Min(.56f, bounds.size.x), bounds.size.y, Mathf.Min(.56f, bounds.size.z));
            Bounds viewBounds = FramingMode == "head" ? CalculateHeadBounds(bounds, Matrix4x4.identity)
                : CropBoundsForVisibleRatio(bounds, visibleBodyRatio);
            if (FramingMode == "upper_body")
            {
                viewBounds = CropBoundsForVisibleRatio(bounds, .4f);
                Vector3 size = viewBounds.size;
                size.x = Mathf.Min(size.x, size.y * .55f);
                size.z = Mathf.Min(size.z, size.y * .2f);
                viewBounds.size = size;
            }
            if (!hasDeskRecoveryDirection)
            {
                Vector3 direction = transform.position - bounds.center;
                if (direction.sqrMagnitude < .01f) return false;
                deskRecoveryDirection = direction.normalized; hasDeskRecoveryDirection = true;
            }
            Bounds exclusion = subject; exclusion.Expand(.16f);
            for (float angle = 58f; angle <= 112f; angle += 2f)
            {
                CameraPose candidate = CalculatePose(viewBounds, deskRecoveryDirection, Vector3.up, angle,
                    Mathf.Max(.01f, GetComponent<Camera>().aspect), 1f, minDistance, topSafeViewport, bottomSafeViewport);
                if (candidate.Position.y > 2.95f || !navigation.ContainsCamera(candidate.Position) || exclusion.Contains(candidate.Position)) continue;
                pose = candidate; fov = angle; return true;
            }
            return false;
        }

        // Presence may prepare before account ownership enables the mesh. This
        // samples its real geometry without ever releasing either visibility
        // gate, and only while that transaction has disabled Home framing.
        internal bool FrameHiddenHomePresentation(Transform avatar)
        {
            if (enabled || !gameObject.activeInHierarchy || !autoFrameEnabled ||
                avatar == null || targetRoot != avatar)
                return false;
            targetCamera = targetCamera != null ? targetCamera : GetComponent<Camera>();
            if (targetCamera == null) return false;
            avatar.GetComponentsInChildren(false, renderers);
            if (HasVisibleRenderer(renderers) || !HasVisibleHomeRoom(true)) return false;
            if (!TryCalculateCurrentPose(out CameraPose pose, out float fieldOfView, true)) return false;
            transitionActive = false;
            transform.SetPositionAndRotation(pose.Position, pose.Rotation);
            ApplyFieldOfView(fieldOfView, true);
            hasFramedPose = true;
            return true;
        }

        private bool TryCalculateCurrentPose(out CameraPose pose, out float fieldOfView,
            bool includeHiddenRenderers = false,bool bypassEntrySafety=false)
        {
            pose = default;
            targetCamera = targetCamera != null ? targetCamera : GetComponent<Camera>();
            fieldOfView = targetCamera != null ? targetCamera.fieldOfView : 60f;
            if (targetCamera == null)
            {
                return false;
            }

            if (targetRoot == null && autoFindTarget)
            {
                targetRoot = FindDefaultTarget();
            }

            if (targetRoot == null || !TryGetTargetBounds(targetRoot, renderers, out Bounds bounds,
                includeHiddenRenderers))
            {
                return false;
            }

            bool fitInsideHome = visibleBodyRatio >= 0.999f &&
                HasVisibleHomeRoom(includeHiddenRenderers);
            if (!fitInsideHome)
            {
                if (homeFieldOfViewAdjusted || (includeHiddenRenderers && hasAuthoredHomeFieldOfView))
                    fieldOfView = authoredHomeFieldOfView;
                if (homeViewReference == null) hasAuthoredHomeFieldOfView = false;
            }
            else
            {
                RememberHomeFieldOfView();
                fieldOfView = authoredHomeFieldOfView;
            }

            pose = CalculateFramedPose(bounds, fitInsideHome, Matrix4x4.identity, ref fieldOfView);
            if (!bypassEntrySafety && entrySafetyRig != null && entrySafetyRig.IsSceneEntryBound &&
                entrySafetyRig.SceneEntry.SceneRoot.parent == entrySafetyParent &&
                entrySafetyRig.SceneEntry.SceneRevision==entrySafetyRevision)
            {
                var nav=entrySafetyRig.Navigation;
                if(entryRoutedAvatar==targetRoot&&nav!=null)
                {
                    if(!TryFitDoorwayPose(entrySafetyRig,ref pose,ref fieldOfView)||
                        !nav.CameraSegmentIsClear(transform.position,pose.Position)||
                        (nav.CrossesBedroomPortal(transform.position,new[]{pose.Position})&&!nav.BedroomDoor.IsOpen))
                    {pose=new CameraPose(transform.position,transform.rotation);fieldOfView=targetCamera.fieldOfView;}
                }
                else if(entrySafetyRig.MustHoldInLobby(targetRoot,pose.Position))
                {pose=entrySafetyRig.LobbyPose;fieldOfView=entrySafetyRig.EntryFieldOfView(fieldOfView);}
            }
            return true;
        }

        private CameraPose CalculateFramedPose(Bounds bounds, bool fitInsideHome,
            Matrix4x4 pointProjection, ref float fieldOfView)
        {
            if(FramingMode=="desk_over_shoulder" && HasDeskWorkAnchor)
            {
                Animator humanoid=FindHumanoidAnimator(targetRoot);
                Transform head=humanoid!=null?humanoid.GetBoneTransform(HumanBodyBones.Head):null;
                if(head!=null)
                {
                    fieldOfView=58f;
                    Bounds workBounds=new(deskWorkSeat.position+Vector3.up*.10f,Vector3.one*.10f);
                    workBounds.Encapsulate(head.position+Vector3.up*.13f);
                    workBounds.Encapsulate(deskWorkSurface.position+deskWorkSeat.forward*.16f);
                    foreach(var bone in new[]{HumanBodyBones.LeftHand,HumanBodyBones.RightHand})
                    {
                        var hand=humanoid.GetBoneTransform(bone);if(hand!=null)workBounds.Encapsulate(hand.position);
                    }
                    workBounds.Expand(new Vector3(.20f,.10f,.15f));
                    Vector3 rearAbove=(-deskWorkSeat.forward*.85f+Vector3.up*.60f+deskWorkSeat.right*.22f).normalized;
                    return CalculatePose(workBounds,rearAbove,Vector3.up,fieldOfView,
                        Mathf.Max(.01f,targetCamera.aspect),1.05f,minDistance,topSafeViewport,bottomSafeViewport);
                }
            }
            if (FramingMode == "sleeping_top")
            {
                // The existing camera coordinator selects this only after the
                // rendered pose confirms lying. Keep the room's north stable.
                fieldOfView = 58f;
                CameraPose topPose = default;
                // The real Coastal ceiling is 3.2m. Widen this same lens before
                // ever backing above it; an outside-room top camera sees plaster.
                for (int step = 0; step < 36; step++)
                {
                    topPose = CalculatePose(bounds, Vector3.up, Vector3.back,
                        fieldOfView, Mathf.Max(.01f, targetCamera.aspect), 1.12f,
                        minDistance, topSafeViewport, bottomSafeViewport);
                    if (topPose.Position.y <= 2.95f) break;
                    fieldOfView = Mathf.Min(128f, fieldOfView + 2f);
                }
                return topPose;
            }
            Bounds framedBounds = FramingMode == "head"
                ? CalculateHeadBounds(bounds, pointProjection)
                : CropBoundsForVisibleRatio(bounds, visibleBodyRatio);
            if (FramingMode == "upper_body")
            {
                // Outstretched arms or wide sleeves must not turn a speaking
                // portrait back into a full-body shot on a narrow phone.
                // Compose head-to-waist; the bottom UI safety margin already
                // leaves room below this region for hands and the lower torso.
                framedBounds = CropBoundsForVisibleRatio(bounds, 0.4f);
                Vector3 size = framedBounds.size;
                size.x = Mathf.Min(size.x, size.y * 0.55f);
                size.z = Mathf.Min(size.z, size.y * 0.2f);
                framedBounds.size = size;
            }
            ResolveViewAxes(out Vector3 viewFront, out Vector3 viewUp);
            CameraPose pose = CalculatePose(
                framedBounds,
                viewFront,
                viewUp,
                fieldOfView,
                Mathf.Max(0.01f, targetCamera.aspect),
                framingPadding,
                minDistance,
                topSafeViewport,
                bottomSafeViewport);

            if (fitInsideHome)
            {
                pose = FitHomeRoomPose(framedBounds, viewFront, viewUp, pose,
                    out fieldOfView);
            }

            return pose;
        }

        private void ApplyFieldOfView(float fieldOfView, bool includeHiddenAvatar = false)
        {
            // Once an indoor adjustment has been released, a desktop/portal
            // camera's explicit lens belongs to that presentation. Do not
            // adopt it as another Home adjustment on the next frame.
            bool ownsHomeLens = homeFieldOfViewAdjusted ||
                (visibleBodyRatio >= 0.999f && HasVisibleHomeRoom(includeHiddenAvatar));
            targetCamera.fieldOfView = fieldOfView;
            homeFieldOfViewAdjusted = ownsHomeLens && hasAuthoredHomeFieldOfView &&
                !Mathf.Approximately(fieldOfView, authoredHomeFieldOfView);
        }

        private bool HasVisibleHomeRoom(bool includeHiddenAvatar = false)
        {
            // A retained reference supplies heading in other presentations too.
            // Portal capture removes the avatar from this camera; desktop pets
            // render only the avatar layer over transparent RGBA.
            if (homeViewReference == null || homeMap == null ||
                homeMap.HomeCameraReference != homeViewReference ||
                targetCamera.orthographic ||
                (targetCamera.clearFlags != CameraClearFlags.Skybox &&
                    targetCamera.backgroundColor.a < 0.99f) ||
                !(includeHiddenAvatar ? HasCameraLayerGeometry(renderers) : HasVisibleRenderer(renderers)))
                return false;

            Transform environmentRoot = homeMap.PersistentEnvironmentRoot;
            if (environmentRoot == null || !environmentRoot.gameObject.activeInHierarchy)
                return false;
            if (cachedHomeEnvironmentRoot != environmentRoot || homeEnvironmentRenderers.Count == 0)
            {
                cachedHomeEnvironmentRoot = environmentRoot;
                environmentRoot.GetComponentsInChildren(true, homeEnvironmentRenderers);
            }
            return HasVisibleRenderer(homeEnvironmentRenderers);
        }

        private bool HasCameraLayerGeometry(List<Renderer> candidates)
        {
            foreach (Renderer renderer in candidates)
            {
                if (renderer != null && renderer.gameObject.activeInHierarchy &&
                    renderer is not ParticleSystemRenderer && renderer is not TrailRenderer &&
                    renderer is not LineRenderer &&
                    (targetCamera.cullingMask & (1 << renderer.gameObject.layer)) != 0)
                    return true;
            }
            return false;
        }

        private bool HasVisibleRenderer(List<Renderer> candidates)
        {
            foreach (Renderer renderer in candidates)
            {
                if (renderer != null && renderer.enabled && !renderer.forceRenderingOff &&
                    renderer.gameObject.activeInHierarchy &&
                    (targetCamera.cullingMask & (1 << renderer.gameObject.layer)) != 0)
                    return true;
            }
            return false;
        }

        private void RememberHomeFieldOfView()
        {
            targetCamera = targetCamera != null ? targetCamera : GetComponent<Camera>();
            if (!hasAuthoredHomeFieldOfView && targetCamera != null)
            {
                authoredHomeFieldOfView = targetCamera.fieldOfView;
                hasAuthoredHomeFieldOfView = true;
            }
        }

        private void RestoreHomeFieldOfView()
        {
            if (homeFieldOfViewAdjusted && targetCamera != null)
                targetCamera.fieldOfView = authoredHomeFieldOfView;
            homeFieldOfViewAdjusted = false;
        }

        private CameraPose FitHomeRoomPose(Bounds bounds, Vector3 front, Vector3 up,
            CameraPose authoredPose, out float fieldOfView)
        {
            // Keep the room's viewing direction and the full avatar safe area.
            // Narrow phones widen the lens instead of backing through the wall.
            Vector3 direction = front.normalized;
            float maximumDistance = Mathf.Min(HomeRoomCameraDistance,
                Vector3.Dot(homeViewReference.position - bounds.center, direction));
            fieldOfView = authoredHomeFieldOfView;
            if (Vector3.Dot(authoredPose.Position - bounds.center, direction) <= maximumDistance)
                return authoredPose;

            float lower = authoredHomeFieldOfView;
            float upper = 179f;
            CameraPose Fit(float angle) => CalculatePose(bounds, front, up, angle,
                Mathf.Max(0.01f, targetCamera.aspect), framingPadding, minDistance,
                topSafeViewport, bottomSafeViewport);
            CameraPose fittedPose = Fit(upper);
            for (int iteration = 0; iteration < 18; iteration++)
            {
                float middle = (lower + upper) * 0.5f;
                CameraPose candidate = Fit(middle);
                if (Vector3.Dot(candidate.Position - bounds.center, direction) > maximumDistance)
                    lower = middle;
                else
                {
                    upper = middle;
                    fittedPose = candidate;
                }
            }
            fieldOfView = upper;
            return fittedPose;
        }

        private void ResolveViewAxes(out Vector3 front, out Vector3 up)
        {
            if (homeViewReference != null)
            {
                stableHomeFront = -homeViewReference.forward;
                stableHomeUp = homeViewReference.up;
                hasStableHomeView = true;
            }
            else if (!hasStableHomeView)
            {
                // Authoring previews without a room keep their first valid
                // viewing direction across poses, target swaps and re-enables.
                stableHomeFront = targetRoot.forward;
                stableHomeUp = Vector3.up;
                hasStableHomeView = true;
            }
            front = stableHomeFront;
            up = stableHomeUp;
        }

        private Bounds CalculateHeadBounds(Bounds bodyBounds, Matrix4x4 pointProjection)
        {
            float bodyHeight = Mathf.Max(0.1f, bodyBounds.size.y);
            Animator animator = FindHumanoidAnimator(targetRoot);
            Transform head = animator != null ? animator.GetBoneTransform(HumanBodyBones.Head) : null;
            if (head == null)
            {
                Bounds fallback = CropBoundsForVisibleRatio(bodyBounds, 0.25f);
                fallback.size = new Vector3(
                    Mathf.Min(bodyBounds.size.x, fallback.size.y * 0.62f),
                    fallback.size.y,
                    Mathf.Min(bodyBounds.size.z, fallback.size.y * 0.35f));
                return fallback;
            }

            Transform neck = animator.GetBoneTransform(HumanBodyBones.Neck);
            Vector3 headPosition = pointProjection.MultiplyPoint3x4(head.position);
            Vector3 neckPosition = neck != null ? pointProjection.MultiplyPoint3x4(neck.position) : Vector3.zero;
            float top = Mathf.Clamp(bodyBounds.max.y,
                headPosition.y + bodyHeight * 0.07f,
                headPosition.y + bodyHeight * 0.18f);
            float bottom = Mathf.Clamp(neck != null ? neckPosition.y - bodyHeight * 0.025f
                    : headPosition.y - bodyHeight * 0.1f,
                headPosition.y - bodyHeight * 0.14f,
                headPosition.y - bodyHeight * 0.05f);
            float height = top - bottom;
            return new Bounds(
                new Vector3(headPosition.x, (top + bottom) * 0.5f, headPosition.z),
                new Vector3(height * 0.62f, height, height * 0.35f));
        }

        public static Bounds CropBoundsForVisibleRatio(
            Bounds bounds,
            float requestedRatio)
        {
            float ratio = float.IsNaN(requestedRatio)
                ? 1f
                : Mathf.Clamp(requestedRatio, 0.25f, 1f);
            if (ratio >= 0.999f)
            {
                return bounds;
            }
            Vector3 minimum = bounds.min;
            Vector3 maximum = bounds.max;
            minimum.y = maximum.y - (bounds.size.y * ratio);
            var cropped = new Bounds();
            cropped.SetMinMax(minimum, maximum);
            return cropped;
        }

        public static CameraPose CalculatePose(
            Bounds bounds,
            Vector3 targetForward,
            Vector3 targetUp,
            float verticalFieldOfView,
            float aspect,
            float padding,
            float minimumDistance)
        {
            return CalculatePose(
                bounds,
                targetForward,
                targetUp,
                verticalFieldOfView,
                aspect,
                padding,
                minimumDistance,
                0f,
                0f);
        }

        public static CameraPose CalculatePose(
            Bounds bounds,
            Vector3 targetForward,
            Vector3 targetUp,
            float verticalFieldOfView,
            float aspect,
            float padding,
            float minimumDistance,
            float topSafeViewport,
            float bottomSafeViewport)
        {
            Vector3 frontDirection = targetForward.sqrMagnitude > 0.0001f
                ? targetForward.normalized
                : Vector3.forward;
            Vector3 upDirection = targetUp.sqrMagnitude > 0.0001f
                ? targetUp.normalized
                : Vector3.up;

            if (Mathf.Abs(Vector3.Dot(frontDirection, upDirection)) > 0.98f)
            {
                upDirection = Vector3.up;
            }

            Vector3 rightDirection = Vector3.Cross(upDirection, frontDirection).normalized;
            if (rightDirection.sqrMagnitude < 0.0001f)
            {
                rightDirection = Vector3.right;
            }

            upDirection = Vector3.Cross(frontDirection, rightDirection).normalized;

            float safePadding = Mathf.Max(1f, padding);
            float safeAspect = Mathf.Max(0.01f, aspect);
            float safeTop = Mathf.Clamp(topSafeViewport, 0f, 0.45f);
            float safeBottom = Mathf.Clamp(bottomSafeViewport, 0f, 0.45f);
            float safeVerticalHalfRange = Mathf.Max(0.1f, 1f - safeTop - safeBottom);
            float safeVerticalCenter = safeBottom - safeTop;
            float safeTopNdc = 1f - (2f * safeTop);
            float safeBottomNdc = -1f + (2f * safeBottom);
            float verticalRadians = Mathf.Clamp(verticalFieldOfView, 1f, 179f) * Mathf.Deg2Rad;
            float verticalTan = Mathf.Tan(verticalRadians * 0.5f);
            float horizontalTan = verticalTan * safeAspect;
            float verticalDistance = minimumDistance;
            float horizontalDistance = minimumDistance;
            Vector3 extents = bounds.extents;

            for (int x = -1; x <= 1; x += 2)
            {
                for (int y = -1; y <= 1; y += 2)
                {
                    for (int z = -1; z <= 1; z += 2)
                    {
                        Vector3 offset = new Vector3(extents.x * x, extents.y * y, extents.z * z);
                        float frontOffset = Vector3.Dot(offset, frontDirection);
                        float upOffset = Vector3.Dot(offset, upDirection);
                        float rightOffset = Vector3.Dot(offset, rightDirection);

                        float topRequiredDistance =
                            (upOffset + (safeTopNdc * verticalTan * frontOffset)) /
                            (safeVerticalHalfRange * verticalTan);
                        float bottomRequiredDistance =
                            -(upOffset + (safeBottomNdc * verticalTan * frontOffset)) /
                            (safeVerticalHalfRange * verticalTan);
                        float horizontalRequiredDistance =
                            frontOffset + (Mathf.Abs(rightOffset) / horizontalTan);

                        verticalDistance = Mathf.Max(
                            verticalDistance,
                            topRequiredDistance,
                            bottomRequiredDistance);
                        horizontalDistance = Mathf.Max(horizontalDistance, horizontalRequiredDistance);
                    }
                }
            }

            float distance = Mathf.Max(Mathf.Max(verticalDistance, horizontalDistance) * safePadding, minimumDistance);

            float visibleHalfHeight = verticalTan * distance;
            Vector3 lookAt = bounds.center - upDirection * (safeVerticalCenter * visibleHalfHeight);
            Vector3 position = lookAt + frontDirection * distance;
            Quaternion rotation = Quaternion.LookRotation(lookAt - position, upDirection);
            return new CameraPose(position, rotation);
        }

        private void Awake()
        {
            targetCamera = GetComponent<Camera>();
            FrameNow();
        }

        private void OnEnable()
        {
            targetCamera = GetComponent<Camera>();
            FrameNow();
        }

        private void LateUpdate()
        {
            AdvanceOwnedFramingFrame(Time.unscaledDeltaTime, Time.realtimeSinceStartup);
        }

        // The embedded player can supply zero or tiny engine deltas. Only the
        // desk journey and its Home return share the furniture's monotonic
        // clock; other camera policies keep their existing engine delta.
        internal void AdvanceOwnedFramingFrame(float engineDelta, float realtimeNow)
        {
            ValidatePresenceCameraRoute();
            if (!autoFrameEnabled || !isActiveAndEnabled)
            {
                deskTravelLastRealtime = -1f;
                return;
            }
            float delta = engineDelta;
            if (deskTravelActive)
            {
                if (targetRoot != deskTravelRoot || GetComponent<WorldCameraDirector>()?.OwnsCamera == true)
                    ResetDeskTravel();
                else
                {
                    float elapsed = deskTravelLastRealtime < 0f ? 0f : realtimeNow - deskTravelLastRealtime;
                    deskTravelLastRealtime = realtimeNow;
                    delta = Mathf.Clamp(Mathf.Max(!float.IsNaN(engineDelta) && !float.IsInfinity(engineDelta) ? engineDelta : 0f,
                        !float.IsNaN(elapsed) && !float.IsInfinity(elapsed) ? elapsed : 0f), 0f, .1f);
                }
            }
            AdvanceFraming(delta);
            if (deskTravelActive && hasDeskTravelGoal && Vector3.Distance(transform.position, deskTravelGoal.Position) < .02f &&
                Quaternion.Angle(transform.rotation, deskTravelGoal.Rotation) < 1f &&
                Mathf.Abs(GetComponent<Camera>().fieldOfView - deskTravelGoalFieldOfView) < .2f)
            {
                if (deskDiagnosticPending) { LogDeskCamera("completed", FramingMode, delta); deskDiagnosticPending = false; }
                if (deskTravelRecovering && !furniturePoseActive) ResetDeskTravel();
            }
        }

        private void LogDeskBlocked(string phase, float delta, Bounds subject = default)
        {
            if (!deskDiagnosticPending || deskDiagnosticBlocked) return;
            deskDiagnosticBlocked = true;
            Bounds exclusion = subject; exclusion.Expand(.16f);
            var navigation = entrySafetyRig != null ? entrySafetyRig.Navigation : null;
            LogDeskCamera(phase, FramingMode, delta,
                $" subjectCenter={subject.center} subjectSize={subject.size} insideSubject={exclusion.Contains(transform.position)} " +
                $"goal={deskTravelGoal.Position} startInRoom={navigation != null && navigation.ContainsCamera(transform.position)} " +
                $"goalInRoom={navigation != null && navigation.ContainsCamera(deskTravelGoal.Position)} goalInsideSubject={exclusion.Contains(deskTravelGoal.Position)}");
        }

        private void LogDeskCamera(string phase, string requested, float delta, string details = "")
        {
            var navigation = entrySafetyRig != null ? entrySafetyRig.Navigation : null;
            Animator animator = targetRoot != null ? FindHumanoidAnimator(targetRoot) : null;
            Transform head = animator != null ? animator.GetBoneTransform(HumanBodyBones.Head) : null;
            Debug.Log($"[UnityAvatar] deskCamera phase={phase} requested={requested} actual={FramingMode} enabled={isActiveAndEnabled} " +
                $"auto={autoFrameEnabled} worldOwns={GetComponent<WorldCameraDirector>()?.OwnsCamera == true} " +
                $"delta={delta:F6} " +
                $"position={transform.position} fov={GetComponent<Camera>().fieldOfView:F2} " +
                $"cameraInRoom={navigation != null && navigation.ContainsCamera(transform.position)} navRevision={navigation?.Revision} " +
                $"layoutRevision={navigation?.LayoutRevision} entryRevision={entrySafetyRevision} " +
                $"navPosition={(navigation != null ? navigation.transform.position : Vector3.zero)} navScale={(navigation != null ? navigation.transform.lossyScale : Vector3.zero)} " +
                $"modelRoot={(targetRoot != null ? targetRoot.position : Vector3.zero)} head={(head != null ? head.position : Vector3.zero)} " +
                $"seat={(deskWorkSeat != null ? deskWorkSeat.position : Vector3.zero)}{details}");
        }

        private void ResetDeskTravel()
        {
            deskTravelActive = false; deskTravelRecovering = false;
            deskTravelRoot = null; deskTravelLastRealtime = -1f; hasDeskTravelGoal = false;
            hasDeskRecoveryDirection = false;
            deskDiagnosticPending = false; deskDiagnosticBlocked = false;
        }

        private void OnApplicationPause(bool paused) { if (paused) deskTravelLastRealtime = -1f; }

        private void OnDisable()
        {
            deskTravelLastRealtime = -1f;
            transitionActive = false;
            RestoreHomeFieldOfView();
        }

        private void OnValidate()
        {
            framingPadding = Mathf.Max(1f, framingPadding);
            minDistance = Mathf.Max(0.1f, minDistance);
            topSafeViewport = Mathf.Clamp(topSafeViewport, 0f, 0.45f);
            bottomSafeViewport = Mathf.Clamp(bottomSafeViewport, 0f, 0.45f);
            visibleBodyRatio = Mathf.Clamp(visibleBodyRatio, 0.25f, 1f);
            targetCamera = GetComponent<Camera>();
        }

        private bool TryGetTargetBounds(Transform root, List<Renderer> rendererBuffer, out Bounds bounds,
            bool includeHiddenRenderers = false)
        {
            if (!furniturePoseActive && !includeHiddenRenderers && hasCachedLocalBounds && cachedBoundsRoot == root)
            {
                bounds = TransformBounds(root, cachedLocalBounds);
                return true;
            }

            // Furniture changes only a few Humanoid bones. CPU skinning the
            // complete model every frame would defeat the normal cached path.
            if (furniturePoseActive && TryGetHumanoidBounds(root, out bounds)) return true;

            if (!AvatarVisualBounds.TryGetCurrent(root, rendererBuffer, out Bounds currentBounds,
                    includeHiddenRenderers) &&
                !TryGetHumanoidBounds(root, out currentBounds))
            {
                bounds = default;
                return false;
            }

            Bounds localBounds = InverseTransformBounds(root, currentBounds);
            // Doorway/focus queries need the current animated body, but must
            // not replace an established standing composition on every frame.
            // An initial hidden preparation may still seed the Home-return
            // cache; target and furniture changes explicitly invalidate it.
            if ((!includeHiddenRenderers && !furniturePoseActive) ||
                !hasCachedLocalBounds || cachedBoundsRoot == null)
            {
                cachedLocalBounds = localBounds;
                cachedBoundsRoot = root;
                hasCachedLocalBounds = true;
            }
            bounds = TransformBounds(root, localBounds);
            return true;
        }

        private static Bounds InverseTransformBounds(Transform root, Bounds worldBounds)
        {
            return TransformBoundsCorners(worldBounds, root.worldToLocalMatrix);
        }

        private static Bounds TransformBounds(Transform root, Bounds localBounds)
        {
            return TransformBoundsCorners(localBounds, root.localToWorldMatrix);
        }

        private static Bounds TransformBoundsCorners(
            Bounds source,
            Matrix4x4 matrix)
        {
            Vector3 extents = source.extents;
            Bounds result = default;
            bool hasPoint = false;

            for (int x = -1; x <= 1; x += 2)
            {
                for (int y = -1; y <= 1; y += 2)
                {
                    for (int z = -1; z <= 1; z += 2)
                    {
                        Vector3 point = source.center + new Vector3(
                            extents.x * x,
                            extents.y * y,
                            extents.z * z);
                        Vector3 transformed = matrix.MultiplyPoint3x4(point);
                        if (!hasPoint)
                        {
                            result = new Bounds(transformed, Vector3.zero);
                            hasPoint = true;
                        }
                        else
                        {
                            result.Encapsulate(transformed);
                        }
                    }
                }
            }

            return result;
        }

        private static bool TryGetHumanoidBounds(Transform root, out Bounds bounds)
        {
            bounds = default;
            Animator animator = FindHumanoidAnimator(root);
            if (animator == null)
            {
                return false;
            }

            bool hasBounds = false;
            for (int i = 0; i < FramingBones.Length; i++)
            {
                Transform bone = animator.GetBoneTransform(FramingBones[i]);
                if (bone == null)
                {
                    continue;
                }

                if (!hasBounds)
                {
                    bounds = new Bounds(bone.position, Vector3.zero);
                    hasBounds = true;
                }
                else
                {
                    bounds.Encapsulate(bone.position);
                }
            }

            if (!hasBounds || bounds.size.y < 0.2f)
            {
                return false;
            }

            Vector3 min = bounds.min;
            Vector3 max = bounds.max;
            min.x -= HumanoidHorizontalPadding;
            max.x += HumanoidHorizontalPadding;
            min.y -= HumanoidBottomPadding;
            max.y += HumanoidTopPadding;
            min.z -= HumanoidDepthPadding;
            max.z += HumanoidDepthPadding;
            bounds.SetMinMax(min, max);
            return true;
        }

        private static Animator FindHumanoidAnimator(Transform root)
        {
            Animator localAnimator = root.GetComponentInChildren<Animator>(false);
            if (IsUsableHumanoid(localAnimator))
            {
                return localAnimator;
            }

            Animator parentAnimator = root.GetComponentInParent<Animator>();
            return IsUsableHumanoid(parentAnimator) ? parentAnimator : null;
        }

        private static bool IsUsableHumanoid(Animator animator)
        {
            return animator != null &&
                   animator.avatar != null &&
                   animator.avatar.isValid &&
                   animator.avatar.isHuman;
        }

        private static Transform FindDefaultTarget()
        {
            SkinnedMeshRenderer[] skinnedMeshes =
                Object.FindObjectsByType<SkinnedMeshRenderer>(FindObjectsInactive.Exclude);

            for (int i = 0; i < skinnedMeshes.Length; i++)
            {
                SkinnedMeshRenderer skinnedMesh = skinnedMeshes[i];
                if (skinnedMesh == null || skinnedMesh.GetComponentInParent<Camera>() != null)
                {
                    continue;
                }

                Transform root = skinnedMesh.transform.root;
                if (root != null)
                {
                    return root;
                }
            }

            return null;
        }
    }

    public readonly struct CameraPose
    {
        public CameraPose(Vector3 position, Quaternion rotation)
        {
            Position = position;
            Rotation = rotation;
        }

        public Vector3 Position { get; }

        public Quaternion Rotation { get; }
    }
}
