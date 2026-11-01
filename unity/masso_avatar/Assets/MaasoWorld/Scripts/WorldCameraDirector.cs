using System;
using System.Collections.Generic;
using Maaso.Avatar;
using UnityEngine;

namespace Maaso.World
{
    public enum WorldCameraPhase
    {
        Home,
        Joining,
        Entering,
        Active,
        Leaving,
    }

    [DisallowMultipleComponent]
    [ExecuteAlways]
    public sealed class WorldCameraDirector : MonoBehaviour
    {
        public const float EnterDurationSeconds = 1.2f;
        public const float ExitDurationSeconds = 1.0f;
        public const float WorldFieldOfView = 51f;
        public const float MinimumBirdseyeHeight = 5.5f;
        public const float MaximumBirdseyeHeight = 8.5f;
        public const float PersonalSpaceCameraLimit = 3.2f;
        public const float PersonalSpaceEyeHeight = 1.3f;
        public const float PersonalSpaceFollowDistance = 3.2f;

        private static readonly Vector3 BirdseyeOffset = new(0f, 6.2f, 7.2f);

        private Camera targetCamera;
        private FrontFullBodyCamera homeFraming;
        private Transform ownerTarget;
        private PersistentWorldMapController worldMap;
        private Vector3 homePosition;
        private Quaternion homeRotation = Quaternion.identity;
        private float homeFieldOfView = 60f;
        private string homeFramingMode = "hero_full_body";
        private Vector3 transitionStartPosition;
        private Quaternion transitionStartRotation = Quaternion.identity;
        private float transitionStartFieldOfView = 60f;
        private float transitionStartedAt;
        private float transitionDurationSeconds;
        private Action transitionCompleted;
        private CameraPose lastBirdseyePose;
        private bool hasBirdseyePose;
        private WorldCameraPhase phase = WorldCameraPhase.Home;
        private bool hasMiniatureBackground;
        private CameraClearFlags previousClearFlags;
        private Color previousBackground;
        private PersonalSpaceNavigation privateNavigation;
        private string privateFurniturePhase="standing",privateCameraMode="hero_full_body";
        private List<Vector3> privateCameraPath;
        private int privateCameraWaypoint;
        private Vector3 privateGoal;
        private float privateCameraTick,privateUnavailableSince=-1;
        private Action<string> privateCameraFailed;
        private bool privateFurnitureTransitioning;
        private List<Vector3> privateExitPath;
        private float privateExitPathLength;
        private bool privatePortraitTransition, homePortraitEligible;
        private float privatePortraitStrength;
        private Transform privateHomeScaleAvatar;
        private Vector3 privateHomeCameraOffset;
        private Quaternion privateHomeCameraRotation;
        private float privateHomeCameraFieldOfView;
        private bool privateCameraModeExplicit;

        public void BindPrivateRoom(PersonalSpaceNavigation navigation,Action<string> failed)
        {
            if(privateNavigation==navigation){privateCameraFailed=failed;return;}
            privateNavigation=navigation;privateCameraFailed=failed;privateCameraPath=null;privateCameraWaypoint=0;privateCameraTick=0;privateUnavailableSince=-1;
            privateFurniturePhase="standing";privateCameraMode="hero_full_body";
            privateFurnitureTransitioning=false;
            privatePortraitTransition = false;
            privatePortraitStrength = 0f;
            privateHomeScaleAvatar=null;privateCameraModeExplicit=false;
        }
        public void SetPrivateCameraMode(string mode)
        {
            if(mode is not ("hero_full_body" or "upper_body" or "sleeping_top"))return;
            privateCameraModeExplicit=mode!="hero_full_body";
            if(mode!="sleeping_top")privateCameraMode=mode;
            privateCameraPath=null;
        }
        public void SetPrivateFurniturePhase(string value)
        {privateFurniturePhase=value;privateFurnitureTransitioning=false;privateCameraPath=null;}
        public void SetPrivateFurnitureTransitioning(bool value)=>privateFurnitureTransitioning=value;

        public bool OwnsCamera => phase != WorldCameraPhase.Home;
        // Runtime owners observe the last rendered update. Phase's legacy
        // editor query can advance time and must not drive a second camera tick.
        public WorldCameraPhase CurrentPhase => phase;
        private float CurrentWorldFieldOfView => WorldFieldOfView;
        private bool IsPersonalSpaceView => worldMap != null &&
            phase != WorldCameraPhase.Home && phase != WorldCameraPhase.Leaving;
        public Transform OcclusionTarget => isActiveAndEnabled && phase != WorldCameraPhase.Home ? ownerTarget : null;

        public WorldCameraPhase Phase
        {
            get
            {
                if (phase == WorldCameraPhase.Entering ||
                    phase == WorldCameraPhase.Leaving)
                {
                    UpdateTransition(Time.realtimeSinceStartup);
                }
                return phase;
            }
        }

        public bool EnterWorld(
            Camera camera,
            FrontFullBodyCamera framing,
            Transform worldOwnerTarget,
            Action onActive)
        {
            if (camera == null || worldOwnerTarget == null)
            {
                return false;
            }

            targetCamera = camera;
            homeFraming = framing;
            ownerTarget = worldOwnerTarget;
            worldMap = privateNavigation != null
                ? privateNavigation.GetComponentInParent<PersistentWorldMapController>()
                : FindAnyObjectByType<PersistentWorldMapController>();
            WorldCameraOcclusion occlusion = camera.GetComponent<WorldCameraOcclusion>();
            if (occlusion == null)
            {
                occlusion = camera.gameObject.AddComponent<WorldCameraOcclusion>();
            }
            occlusion.Configure(this);
            if (phase == WorldCameraPhase.Home)
            {
                homePosition = camera.transform.position;
                homeRotation = camera.transform.rotation;
                homeFieldOfView = camera.fieldOfView;
                homeFramingMode = framing?.FramingMode ?? "hero_full_body";
            }

            transitionStartPosition = camera.transform.position;
            transitionStartRotation = camera.transform.rotation;
            transitionStartFieldOfView = camera.fieldOfView;
            var privateLease=privateNavigation!=null?worldOwnerTarget.GetComponent<WorldOwnerAvatarLease>():null;
            privateHomeScaleAvatar=privateLease?.IsBound==true?privateLease.AvatarRoot:null;
            if(privateHomeScaleAvatar!=null)
            {
                // The default room view inherits the real Home image. A
                // larger available viewport must not zoom the selected actor.
                privateHomeCameraOffset=camera.transform.position-privateHomeScaleAvatar.position;
                privateHomeCameraRotation=camera.transform.rotation;
                privateHomeCameraFieldOfView=camera.fieldOfView;
                if(framing!=null && (framing.VisibleBodyRatio<.999f || framing.IsTransitioningToDefaultFullBody) &&
                    framing.TryGetDefaultHomeFullBodyFramingPose(privateHomeScaleAvatar,
                        privateNavigation.GetComponent<LoginDoorwayRig>(),out CameraPose fullBody,out float fullBodyFov))
                {
                    // Restore input-focused upper/head framing smoothly toward
                    // Home's default full body, with its authored room margins.
                    privateHomeCameraOffset=fullBody.Position-privateHomeScaleAvatar.position;
                    privateHomeCameraRotation=fullBody.Rotation;
                    privateHomeCameraFieldOfView=fullBodyFov;
                }
            }
            transitionStartedAt = Time.realtimeSinceStartup;
            transitionCompleted = onActive;
            hasBirdseyePose = false;
            homePortraitEligible = privateNavigation != null &&
                camera.GetComponent<PortraitDepthOfField>()?.CanRender == true;
            privatePortraitTransition = privateNavigation != null;
            privatePortraitStrength = 1f;
            if (homeFraming != null)
            {
                homeFraming.enabled = false;
            }
            // OnDisable restores the authored Home lens. Camera ownership
            // starts with the image actually displayed, including a close shot.
            targetCamera.fieldOfView = transitionStartFieldOfView;
            phase = WorldCameraPhase.Entering;
            transitionDurationSeconds = EnterDurationSeconds;
            UpdateMiniaturePresentation();

            UpdateTransition(Time.realtimeSinceStartup);
            return true;
        }

        public bool PreparePrivateEntryRoute()
        {
            if (!TryGetPrivateDestination(out CameraPose destination, out _, out Bounds subject)) return false;
            if (!privateNavigation.TryBuildCameraRouteAroundSubject(
                    targetCamera.transform.position, destination.Position, subject, out privateCameraPath))
                return false;
            privateCameraWaypoint = 0;
            privateGoal = destination.Position;
            privateCameraTick = Time.realtimeSinceStartup;
            return true;
        }

        public bool CompletePrivateEntryImmediately()
        {
            if (!TryGetPrivateDestination(out CameraPose destination, out float fieldOfView, out _)) return false;
            targetCamera.transform.SetPositionAndRotation(destination.Position, destination.Rotation);
            targetCamera.fieldOfView = fieldOfView;
            privateCameraPath = null;
            phase = WorldCameraPhase.Active;
            privatePortraitTransition = false;
            privatePortraitStrength = 0f;
            Action completed = transitionCompleted;
            transitionCompleted = null;
            completed?.Invoke();
            return true;
        }

        public void UpdateTarget(Transform worldOwnerTarget)
        {
            ownerTarget = worldOwnerTarget;
        }

        public void BeginExit(Action onHomeRestored)
        {
            float exitDuration = ExitDurationSeconds;
            Debug.Log(
                $"[WorldExit][UnityCamera] BeginExit phase={phase} " +
                $"hasCamera={targetCamera != null} duration={exitDuration:F1}s");
            if (phase == WorldCameraPhase.Home || targetCamera == null)
            {
                Debug.Log("[WorldExit][UnityCamera] already home; callback immediately");
                onHomeRestored?.Invoke();
                return;
            }

            // The saved image can be halfway through a Home camera skill.
            // Return to the shot that Home will actually apply after the lease
            // is restored, using the current Home viewport policy. The avatar
            // may already be elsewhere in a world, so resolve its predicted
            // grounded Home pose without moving the live mesh or camera.
            if (homeFraming != null && worldMap != null)
            {
                homeFraming.SetFramingMode(homeFramingMode);
                if (homeFraming.TryGetHomeReturnFramingPose(
                        worldMap.HomeAgentAnchor, out CameraPose homePose, out float fieldOfView))
                {
                    homePosition = homePose.Position;
                    homeRotation = homePose.Rotation;
                    homeFieldOfView = fieldOfView;
                }
            }

            transitionStartPosition = targetCamera.transform.position;
            transitionStartRotation = targetCamera.transform.rotation;
            transitionStartFieldOfView = targetCamera.fieldOfView;
            privateExitPath = null;
            privatePortraitTransition = false;
            transitionStartedAt = Time.realtimeSinceStartup;
            transitionDurationSeconds = exitDuration;
            transitionCompleted = onHomeRestored;
            phase = WorldCameraPhase.Leaving;
            Debug.Log(
                $"[WorldExit][UnityCamera] transition started at={transitionStartedAt:F3}");
            UpdateTransition(Time.realtimeSinceStartup);
        }

        public bool BeginPrivateExit(Action onHomeRestored)
        {
            if (privateNavigation == null || targetCamera == null || homeFraming == null || ownerTarget == null)
                return false;
            var lease = ownerTarget.GetComponent<WorldOwnerAvatarLease>();
            Transform avatar = lease?.AvatarRoot;
            // The owner is already home. Resolve the actual final room shot and
            // route this same lens around reviewed geometry and the live body.
            homeFraming.SetFramingMode(homeFramingMode);
            if (avatar == null || worldMap?.HomeAgentAnchor == null ||
                !homeFraming.TryGetHomeFramingPose(out CameraPose destination, out float fieldOfView) ||
                !AvatarVisualBounds.TryGetCurrent(avatar, new List<Renderer>(), out Bounds subject) ||
                !privateNavigation.TryBuildCameraRouteAroundSubject(targetCamera.transform.position,
                    destination.Position, subject, out var path))
                return false;
            BeginExit(onHomeRestored);
            homePosition = destination.Position;
            homeRotation = destination.Rotation;
            homeFieldOfView = fieldOfView;
            privateExitPath = path;
            privateExitPathLength = 0f;
            Vector3 previous = transitionStartPosition;
            foreach (Vector3 point in path)
            { privateExitPathLength += Vector3.Distance(previous, point); previous = point; }
            transitionDurationSeconds = Mathf.Max(ExitDurationSeconds, privateExitPathLength / 1.4f,
                Mathf.Abs(homeFieldOfView - transitionStartFieldOfView) / 40f);
            privatePortraitTransition = true;
            privatePortraitStrength = 0f;
            return true;
        }

        public bool TryGetPrivatePortraitStrength(Transform avatar, out float strength)
        {
            strength = 0f;
            if (!isActiveAndEnabled || !homePortraitEligible || !privatePortraitTransition ||
                privateNavigation == null || !privateNavigation.gameObject.activeInHierarchy ||
                homeFraming == null || homeFraming.TargetRoot != avatar || avatar == null ||
                homeFraming.GetComponent<Camera>() != targetCamera || !avatar.gameObject.activeInHierarchy ||
                ownerTarget == null || targetCamera != GetComponent<Camera>() ||
                (phase != WorldCameraPhase.Entering && phase != WorldCameraPhase.Leaving)) return false;
            var lease = ownerTarget.GetComponent<WorldOwnerAvatarLease>();
            if (lease == null || !lease.isActiveAndEnabled || !lease.IsBound || lease.AvatarRoot != avatar) return false;
            strength = Mathf.Clamp01(privatePortraitStrength);
            return true;
        }

        public void EnsureExitToHome()
        {
            if (phase == WorldCameraPhase.Home ||
                phase == WorldCameraPhase.Leaving)
            {
                Debug.Log(
                    $"[WorldExit][UnityCamera] fallback skipped phase={phase}");
                return;
            }

            Debug.Log($"[WorldExit][UnityCamera] fallback exit started phase={phase}");
            BeginExit(null);
        }

        public void RestoreHomeImmediately()
        {
            if (phase == WorldCameraPhase.Home) return;
            if (phase != WorldCameraPhase.Leaving) BeginExit(null);
            UpdateTransition(Time.realtimeSinceStartup + ExitDurationSeconds + 1f);
        }

        public static CameraPose CalculateOwnerBirdseyePose(
            Vector3 ownerPosition,
            float verticalFieldOfView,
            float aspect)
        {
            float height = Mathf.Clamp(
                BirdseyeOffset.y,
                MinimumBirdseyeHeight,
                MaximumBirdseyeHeight);
            float safeFieldOfView = Mathf.Clamp(verticalFieldOfView, 35f, 75f);
            float safeAspect = Mathf.Clamp(aspect, 0.35f, 2.4f);
            float lookAhead = Mathf.Lerp(
                2.2f,
                1.8f,
                Mathf.InverseLerp(45f, 60f, safeFieldOfView));
            lookAhead += Mathf.Clamp((0.5625f - safeAspect) * 0.25f, -0.15f, 0.15f);

            Vector3 position = ownerPosition + new Vector3(
                BirdseyeOffset.x,
                height,
                BirdseyeOffset.z);
            // Keep Home and personal-space views on the room's +Z side so the
            // window and coast on -Z remain behind the owner in both views.
            Vector3 lookAt = ownerPosition + new Vector3(0f, 0.9f, -lookAhead);
            return new CameraPose(
                position,
                Quaternion.LookRotation(lookAt - position, Vector3.up));
        }

        public static Quaternion CalculateOwnerEntryRotation(
            Vector3 ownerPosition,
            float aspect,
            Quaternion fallback)
        {
            PersistentWorldMapController map = FindAnyObjectByType<PersistentWorldMapController>();
            CameraPose birdseyePose = CalculateOwnerBirdseyePose(ownerPosition, WorldFieldOfView, aspect);
            if (map != null)
            {
                Vector3 localOwner = map.transform.InverseTransformPoint(ownerPosition);
                CameraPose room = CalculatePersonalSpacePose(localOwner, localOwner + Vector3.forward);
                birdseyePose = new CameraPose(map.transform.TransformPoint(room.Position),
                    map.transform.rotation * room.Rotation);
            }
            return WorldLocomotionPresentation.ResolveFacing(
                ownerPosition,
                birdseyePose.Position,
                fallback);
        }

        // Coordinates are relative to the room, not to the moving avatar. The
        // source sea camera is 1.30 m high and 3.20 m inside the +Z wall. Keep
        // that eye level and following distance; orbit only when a wall blocks
        // the preferred offset. A clipped offset alone can put the lens inside
        // the avatar when it walks to the back wall.
        public static CameraPose CalculatePersonalSpacePose(
            Vector3 ownerPosition, Vector3 preferredCameraPosition)
        {
            const float limit = PersonalSpaceCameraLimit;
            const float radius = PersonalSpaceFollowDistance;
            Vector3 preferred = preferredCameraPosition - ownerPosition;
            preferred.y = 0f;
            preferred = preferred.sqrMagnitude > .0001f ? preferred.normalized : Vector3.forward;
            Vector3 best = Vector3.zero;
            float bestScore = float.NegativeInfinity;

            void Consider(float x, float z)
            {
                if (x < -limit - .0001f || x > limit + .0001f ||
                    z < -limit - .0001f || z > limit + .0001f) return;
                Vector3 offset = new Vector3(x - ownerPosition.x, 0f, z - ownerPosition.z);
                float score = Vector3.Dot(offset, preferred);
                if (score <= bestScore) return;
                bestScore = score;
                best = new Vector3(Mathf.Clamp(x, -limit, limit), PersonalSpaceEyeHeight,
                    Mathf.Clamp(z, -limit, limit));
            }

            Consider(ownerPosition.x + preferred.x * radius, ownerPosition.z + preferred.z * radius);
            // The closest feasible point on the orbit is either the preferred
            // point or one of its intersections with the four room boundaries.
            for (int side = -1; side <= 1; side += 2)
            {
                float edge = side * limit;
                float dx = edge - ownerPosition.x;
                if (Mathf.Abs(dx) <= radius)
                {
                    float dz = Mathf.Sqrt(Mathf.Max(0f, radius * radius - dx * dx));
                    Consider(edge, ownerPosition.z + dz);
                    Consider(edge, ownerPosition.z - dz);
                }
                float dzEdge = edge - ownerPosition.z;
                if (Mathf.Abs(dzEdge) <= radius)
                {
                    float dxEdge = Mathf.Sqrt(Mathf.Max(0f, radius * radius - dzEdge * dzEdge));
                    Consider(ownerPosition.x - dxEdge, edge);
                    Consider(ownerPosition.x + dxEdge, edge);
                }
            }
            // Legacy network snapshots can still be outside the local room.
            // Keep the camera indoors even if no full orbit fits that target.
            if (float.IsNegativeInfinity(bestScore)) best = new Vector3(0f, PersonalSpaceEyeHeight, 0f);
            Vector3 lookAt = ownerPosition + Vector3.up * .95f;
            return new CameraPose(best, Quaternion.LookRotation(lookAt - best, Vector3.up));
        }

        private CameraPose PersonalSpacePose(Vector3 preferredCameraPosition)
        {
            Transform room = worldMap.transform;
            CameraPose pose = CalculatePersonalSpacePose(room.InverseTransformPoint(ownerTarget.position),
                room.InverseTransformPoint(preferredCameraPosition));
            return new CameraPose(room.TransformPoint(pose.Position), room.rotation * pose.Rotation);
        }

        private void Update()
        {
            UpdateTransition(Time.realtimeSinceStartup);
        }

        private void UpdateTransition(float now)
        {
            if (targetCamera == null)
            {
                return;
            }

            UpdateMiniaturePresentation();

            if(privateNavigation!=null&&(phase==WorldCameraPhase.Entering||phase==WorldCameraPhase.Active)&&IsPersonalSpaceView)
            {
                if (phase == WorldCameraPhase.Entering)
                {
                    float fade = Mathf.Clamp01((now - transitionStartedAt) / EnterDurationSeconds);
                    privatePortraitStrength = 1f - Mathf.SmoothStep(0f, 1f, fade);
                }
                if(UpdatePrivateView(now)&&phase==WorldCameraPhase.Entering&&privatePortraitStrength<=0f)
                {phase=WorldCameraPhase.Active;var complete=transitionCompleted;transitionCompleted=null;complete?.Invoke();}
                return;
            }

            if (phase == WorldCameraPhase.Entering)
            {
                CameraPose destination = CurrentBirdseyePose();
                float progress = transitionDurationSeconds <= 0f ? 1f : Mathf.Clamp01(
                    (now - transitionStartedAt) / transitionDurationSeconds);
                ApplyPose(destination, Mathf.SmoothStep(0f, 1f, progress));
                if (progress >= 1f)
                {
                    phase = WorldCameraPhase.Active;
                    Action completed = transitionCompleted;
                    transitionCompleted = null;
                    completed?.Invoke();
                }
                return;
            }

            if (phase == WorldCameraPhase.Active)
            {
                CameraPose destination = CurrentBirdseyePose();
                float damping = Application.isPlaying
                    ? 1f - Mathf.Exp(-Time.unscaledDeltaTime * 3.5f)
                    : 1f;
                targetCamera.transform.SetPositionAndRotation(
                    Vector3.Lerp(
                        targetCamera.transform.position,
                        destination.Position,
                        damping),
                    Quaternion.Slerp(
                        targetCamera.transform.rotation,
                        destination.Rotation,
                        damping));
                if (IsPersonalSpaceView && ownerTarget != null)
                {
                    // Project the damped position back onto the indoor orbit;
                    // interpolation must not cut through the followed avatar.
                    CameraPose indoor = PersonalSpacePose(targetCamera.transform.position);
                    targetCamera.transform.SetPositionAndRotation(indoor.Position, indoor.Rotation);
                }
                targetCamera.fieldOfView = Mathf.Lerp(
                    targetCamera.fieldOfView,
                    CurrentWorldFieldOfView,
                    damping);
                return;
            }

            if (phase != WorldCameraPhase.Leaving)
            {
                return;
            }

            float exitProgress = transitionDurationSeconds <= 0f ? 1f : Mathf.Clamp01(
                (now - transitionStartedAt) / transitionDurationSeconds);
            float eased = Mathf.SmoothStep(0f, 1f, exitProgress);
            if (privatePortraitTransition) privatePortraitStrength = eased;
            targetCamera.transform.SetPositionAndRotation(
                privateExitPath != null ? PrivateExitPosition(eased) : Vector3.Lerp(transitionStartPosition, homePosition, eased),
                Quaternion.Slerp(transitionStartRotation, homeRotation, eased));
            targetCamera.fieldOfView = Mathf.Lerp(
                transitionStartFieldOfView,
                homeFieldOfView,
                eased);
            if (exitProgress < 1f)
            {
                return;
            }

            targetCamera.transform.SetPositionAndRotation(homePosition, homeRotation);
            targetCamera.fieldOfView = homeFieldOfView;
            phase = WorldCameraPhase.Home;
            privatePortraitTransition = false;
            Debug.Log(
                $"[WorldExit][UnityCamera] transition completed " +
                $"elapsed={(now - transitionStartedAt):F3}s");
            ownerTarget = null;
            hasBirdseyePose = false;
            privateExitPath = null;
            bool completedPrivateReturn = privateNavigation != null;
            Action restored = transitionCompleted;
            transitionCompleted = null;
            restored?.Invoke();
            if (homeFraming != null)
            {
                homeFraming.SetFramingMode(homeFramingMode);
                if (completedPrivateReturn)
                    homeFraming.CompleteSpaceReturnCameraRoute(homeFraming.TargetRoot);
                homeFraming.enabled = true;
            }
        }

        private Vector3 PrivateExitPosition(float progress)
        {
            float remaining = Mathf.Clamp01(progress) * privateExitPathLength;
            Vector3 previous = transitionStartPosition;
            foreach (Vector3 point in privateExitPath)
            {
                float length = Vector3.Distance(previous, point);
                if (remaining <= length && length > .000001f) return Vector3.Lerp(previous, point, remaining / length);
                remaining -= length;
                previous = point;
            }
            return homePosition;
        }

        private void ApplyPose(CameraPose destination, float progress)
        {
            // PersonalSpacePose already constrains the destination to the
            // indoor orbit. Preserve the actual Home camera at progress zero:
            // a head/upper-body shot can start above the world's eye height.
            // Clamping the interpolated position would teleport that first
            // frame even though the requested transition has not begun.
            targetCamera.transform.SetPositionAndRotation(
                Vector3.Lerp(transitionStartPosition, destination.Position, progress),
                Quaternion.Slerp(transitionStartRotation, destination.Rotation, progress));
            targetCamera.fieldOfView = Mathf.Lerp(
                transitionStartFieldOfView,
                CurrentWorldFieldOfView,
                progress);
        }

        private bool UpdatePrivateView(float now)
        {
            if(privateFurnitureTransitioning){privateCameraTick=now;return false;}
            if(!TryGetPrivateDestination(out CameraPose destination,out float fov,out Bounds subject))
            {ReportPrivateViewUnavailable(now);return false;}
            if(privateHomeScaleAvatar!=null && !privateCameraModeExplicit &&
                privateCameraMode=="hero_full_body" && privateFurniturePhase=="standing" &&
                Vector3.Distance(targetCamera.transform.position,destination.Position)<.00001f &&
                Mathf.Abs(targetCamera.fieldOfView-fov)<.0001f &&
                Mathf.Abs(Quaternion.Dot(targetCamera.transform.rotation,destination.Rotation))>.999999f)
            {
                // The source Home image already is this destination. Retain
                // its exact quaternion/lens instead of repeatedly normalizing
                // a stationary shot while only the background effect fades.
                privateCameraTick=now;privateUnavailableSince=-1;privateCameraPath=null;
                return true;
            }
            float delta=privateCameraTick>0?Mathf.Clamp(now-privateCameraTick,0,.1f):0;privateCameraTick=now;
            bool continuousHomeFollow=privateHomeScaleAvatar!=null && !privateCameraModeExplicit &&
                privateCameraMode=="hero_full_body" && privateFurniturePhase=="standing" &&
                !string.IsNullOrWhiteSpace(privateNavigation.Revision) &&
                privateNavigation.CameraSegmentAvoidsSubject(targetCamera.transform.position,destination.Position,subject) &&
                (!privateNavigation.CrossesBedroomPortal(targetCamera.transform.position,new[]{destination.Position}) ||
                    privateNavigation.BedroomDoor!=null && privateNavigation.BedroomDoor.IsOpen);
            if(continuousHomeFollow)
            {
                // Track the newest safe Home-scale target on every frame. A
                // cached short route would arrive, wait for the 18 cm replan
                // threshold, then restart behind the continuously walking actor.
                float followBlend=delta>0?1-Mathf.Exp(-delta*8f):0;
                Vector3 next=Vector3.MoveTowards(targetCamera.transform.position,
                    Vector3.Lerp(targetCamera.transform.position,destination.Position,followBlend),delta*2.4f);
                if(!privateNavigation.CameraSegmentAvoidsSubject(targetCamera.transform.position,next,subject))
                {privateCameraPath=null;ReportPrivateViewUnavailable(now);return false;}
                targetCamera.transform.position=next;
                privateCameraPath=null;privateCameraWaypoint=0;privateGoal=destination.Position;
            }
            else
            {
                if(privateCameraPath==null||Vector3.Distance(privateGoal,destination.Position)>.18f)
                {
                    if(!privateNavigation.TryBuildCameraRouteAroundSubject(targetCamera.transform.position,destination.Position,subject,out privateCameraPath))
                    {privateCameraPath=null;ReportPrivateViewUnavailable(now);return false;}
                    privateCameraWaypoint=0;privateGoal=destination.Position;
                }
                if(privateCameraWaypoint<privateCameraPath.Count)
                {
                    Vector3 point=privateCameraPath[privateCameraWaypoint];
                    if(privateNavigation.CrossesBedroomPortal(targetCamera.transform.position,new[]{point}))
                    {
                        if(privateNavigation.BedroomDoor==null||!privateNavigation.BedroomDoor.RequestOpen())
                        {ReportPrivateViewUnavailable(now);return false;}
                        if(!privateNavigation.BedroomDoor.IsOpen)return false;
                    }
                    Vector3 next=Vector3.MoveTowards(targetCamera.transform.position,point,delta*1.4f);
                    if(!privateNavigation.CameraSegmentAvoidsSubject(targetCamera.transform.position,next,subject))
                    {privateCameraPath=null;ReportPrivateViewUnavailable(now);return false;}
                    targetCamera.transform.position=next;
                    if(Vector3.Distance(next,point)<.002f)privateCameraWaypoint++;
                }
            }
            bool positionReached=continuousHomeFollow
                ? Vector3.Distance(targetCamera.transform.position,destination.Position)<.002f
                : privateCameraWaypoint>=privateCameraPath.Count;
            privateUnavailableSince=-1;
            Vector3 forward=destination.Rotation*Vector3.forward;
            Vector3 focus=destination.Position+forward*Mathf.Max(.3f,Vector3.Dot(subject.center-destination.Position,forward));
            Vector3 look=focus-targetCamera.transform.position;
            Quaternion rotation=look.sqrMagnitude>.001f?Quaternion.LookRotation(look,Mathf.Abs(Vector3.Dot(look.normalized,Vector3.up))>.96f?Vector3.back:Vector3.up):destination.Rotation;
            if(Vector3.Distance(targetCamera.transform.position,destination.Position)<.1f)rotation=destination.Rotation;
            float blend=delta>0?1-Mathf.Exp(-delta*5):0;
            targetCamera.transform.rotation=Quaternion.Slerp(targetCamera.transform.rotation,rotation,blend);
            // A doorway or returning Home viewport can require a much wider
            // destination lens. Bound the angular rate as well as easing so
            // the first frame cannot pulse the body size by several degrees.
            targetCamera.fieldOfView=Mathf.MoveTowards(targetCamera.fieldOfView,
                Mathf.Lerp(targetCamera.fieldOfView,fov,blend),delta*60f);
            return positionReached&&Quaternion.Angle(targetCamera.transform.rotation,destination.Rotation)<1&&Mathf.Abs(targetCamera.fieldOfView-fov)<.5f;
        }

        private bool TryGetPrivateDestination(out CameraPose destination, out float fov, out Bounds subject)
        {
            destination = default;
            fov = 0f;
            subject = default;
            var lease = ownerTarget != null ? ownerTarget.GetComponent<WorldOwnerAvatarLease>() : null;
            Transform avatar = lease?.AvatarRoot;
            var entry = privateNavigation != null ? privateNavigation.GetComponent<LoginDoorwayRig>() : null;
            string mode = privateFurniturePhase == "lying" ? "sleeping_top" : privateCameraMode;
            if(avatar!=null && avatar==privateHomeScaleAvatar && !privateCameraModeExplicit &&
                mode=="hero_full_body" && privateFurniturePhase=="standing")
            {
                if(targetCamera==null || entry==null || !privateNavigation.gameObject.activeInHierarchy ||
                    !AvatarVisualBounds.TryGetCurrent(avatar,new List<Renderer>(),out subject))return false;
                subject.size=new Vector3(Mathf.Min(.56f,subject.size.x),subject.size.y,Mathf.Min(.56f,subject.size.z));
                CameraPose desired=new(avatar.position+privateHomeCameraOffset,privateHomeCameraRotation);
                Vector3 forward=desired.Rotation*Vector3.forward;
                Vector3 focus=desired.Position+forward*Mathf.Max(.3f,Vector3.Dot(subject.center-desired.Position,forward));
                // The reviewed fitter preserves distance*tan(FOV/2), so a
                // wall or doorway can change orbit without enlarging the actor.
                return entry.TryFitWorldCameraDestination(desired,privateHomeCameraFieldOfView,focus,out destination,out fov);
            }
            Vector3 front = mode == "upper_body" && ownerTarget != null ? ownerTarget.forward :
                privateNavigation != null ? privateNavigation.transform.forward : Vector3.forward;
            return targetCamera != null && homeFraming != null && avatar != null && entry != null &&
                privateNavigation.gameObject.activeInHierarchy &&
                homeFraming.TryGetWorldOwnedFramingPose(avatar, mode, entry, front, out destination, out fov, out subject);
        }
        private void ReportPrivateViewUnavailable(float now)
        {
            if(privateUnavailableSince<0){privateUnavailableSince=now;return;}
            if(now-privateUnavailableSince<5)return;
            privateUnavailableSince=float.PositiveInfinity;
            privateCameraFailed?.Invoke("private_camera_route_unavailable");
        }

        private CameraPose CurrentBirdseyePose()
        {
            if (ownerTarget != null)
            {
                if (IsPersonalSpaceView)
                {
                    Vector3 preferred = worldMap.transform.forward;
                    if (hasBirdseyePose && phase == WorldCameraPhase.Active)
                    {
                        Vector3 previous = lastBirdseyePose.Position - ownerTarget.position;
                        previous.y = 0f;
                        preferred = Vector3.Slerp(previous.normalized, preferred, .08f);
                    }
                    lastBirdseyePose = PersonalSpacePose(ownerTarget.position + preferred);
                    hasBirdseyePose = true;
                    return lastBirdseyePose;
                }
                lastBirdseyePose = CalculateOwnerBirdseyePose(ownerTarget.position, WorldFieldOfView, targetCamera.aspect);
                hasBirdseyePose = true;
                return lastBirdseyePose;
            }

            if (hasBirdseyePose)
            {
                return lastBirdseyePose;
            }
            return new CameraPose(
                targetCamera.transform.position,
                targetCamera.transform.rotation);
        }

        private void UpdateMiniaturePresentation()
        {
            if (IsPersonalSpaceView)
            {
                if (!hasMiniatureBackground)
                {
                    previousClearFlags = targetCamera.clearFlags;
                    previousBackground = targetCamera.backgroundColor;
                    hasMiniatureBackground = true;
                }
                targetCamera.clearFlags = CameraClearFlags.SolidColor;
                targetCamera.backgroundColor = new Color(0.96f, 0.93f, 0.87f, 1f);
            }
            else if (hasMiniatureBackground)
            {
                targetCamera.clearFlags = previousClearFlags;
                targetCamera.backgroundColor = previousBackground;
                hasMiniatureBackground = false;
            }
        }

        private void OnDisable()
        {
            if (targetCamera != null && hasMiniatureBackground)
            {
                targetCamera.clearFlags = previousClearFlags;
                targetCamera.backgroundColor = previousBackground;
                hasMiniatureBackground = false;
            }
        }
    }
}
