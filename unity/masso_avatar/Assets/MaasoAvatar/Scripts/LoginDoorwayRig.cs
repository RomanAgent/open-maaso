using System;
using Maaso.World;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>References the room's existing entry. No door is instantiated,
    /// hidden by name, or replaced when a login presentation starts.</summary>
    public sealed class LoginDoorwayRig : MonoBehaviour
    {
        public const string ResourceName = "LoginDoorway"; // Legacy asset identifier only.
        public Transform DoorHinge;
        public Transform ExteriorCamera;
        public Transform ThresholdCamera;
        public Transform InteriorCamera;
        public Transform DoorLookTarget;
        public float DoorOpenDegrees = -100f;
        [SerializeField] private LoginDoorwaySceneBinding sceneEntry;
        private Quaternion closedRotation, acquiredRotation;
        private bool captured;
        private long leaseSequence, activeLease;
        private Transform acquiredSceneParent;
        public LoginDoorwaySceneBinding SceneEntry => sceneEntry;
        public bool IsSceneEntryBound => sceneEntry != null && sceneEntry.IsValid(transform);
        public bool IsReady => DoorHinge != null && ExteriorCamera != null &&
            ThresholdCamera != null && InteriorCamera != null && DoorLookTarget != null &&
            (sceneEntry == null || (IsSceneEntryBound && sceneEntry.SceneRoot.gameObject.activeInHierarchy));

        private void Start()
        {
            // Home, including a restored session that skips the login camera,
            // starts with the room's existing entry closed. An active login
            // lease still owns its opening animation if Start arrives later.
            TrySetSceneDoorOpen(0f);
        }

        public bool BindSceneEntry(LoginDoorwaySceneBinding binding)
        {
            if (binding == null || !binding.IsValid(transform) || binding.DoorLeaf.GetComponentsInChildren<Renderer>(true).Length == 0) return false;
            // Rebinding retires an old lease without touching its old room.
            activeLease = 0; leaseSequence++;
            sceneEntry = binding;
            DoorHinge = binding.DoorHinge; DoorOpenDegrees = binding.DoorOpenDegrees;
            ExteriorCamera = binding.ExteriorCamera; ThresholdCamera = binding.ThresholdCamera;
            InteriorCamera = binding.InteriorCamera; DoorLookTarget = binding.DoorLookTarget;
            closedRotation = binding.ClosedLocalRotation.normalized; captured = true;
            return ValidateEntryRoute();
        }

        public static LoginDoorwayRig Ensure(PersistentWorldMapController map) =>
            BindSceneEntryInEnvironment(map != null ? map.PersistentEnvironmentRoot : null);

        public static LoginDoorwayRig BindSceneEntryInEnvironment(Transform environment)
        {
            if (environment == null || !environment.gameObject.activeInHierarchy) return null;
            LoginDoorwayRig selected = null;
            foreach (var candidate in environment.GetComponentsInChildren<LoginDoorwayRig>(true))
            {
                if (!candidate.gameObject.activeInHierarchy) continue;
                // A retained V2 replacement rig is not a compatible shared door.
                if (!candidate.IsSceneEntryBound) return null;
                if (candidate.sceneEntry.EntryId != "main_entry") continue;
                if (candidate.sceneEntry.SceneRoot != environment && !candidate.sceneEntry.SceneRoot.IsChildOf(environment)) return null;
                if (selected != null || !candidate.IsReady || !candidate.ValidateEntryRoute() ||
                    candidate.sceneEntry.DoorLeaf.GetComponentsInChildren<Renderer>(true).Length == 0) return null;
                selected = candidate;
            }
            return selected;
        }

        public bool TryAcquire(out long lease)
        {
            lease = 0;
            if (!IsReady || activeLease != 0 || (IsSceneEntryBound && !ValidateEntryRoute())) return false;
            if (!captured) { closedRotation = IsSceneEntryBound ? sceneEntry.ClosedLocalRotation.normalized : DoorHinge.localRotation; captured = true; }
            acquiredRotation = DoorHinge.localRotation;
            acquiredSceneParent = IsSceneEntryBound ? sceneEntry.SceneRoot.parent : transform.parent;
            lease = activeLease = ++leaseSequence;
            return true;
        }
        public bool Owns(long lease) => lease > 0 && lease == activeLease && IsReady &&
            (IsSceneEntryBound ? sceneEntry.SceneRoot.parent : transform.parent) == acquiredSceneParent &&
            (!IsSceneEntryBound || ValidateEntryRoute());
        public bool SetOpen(long lease,float progress)
        {
            if (!Owns(lease)) return false;
            DoorHinge.localRotation = closedRotation * Quaternion.Euler(0,DoorOpenDegrees*Mathf.Clamp01(progress),0);
            return true;
        }
        public void Release(long lease,bool restoreOriginal)
        {
            if (lease <= 0 || lease != activeLease) return;
            // Close after a completed/ skipped entry; cancellation restores
            // the room state captured by this exact lease. A rebound room or
            // retired owner must never have its current door pose overwritten.
            if (Owns(lease)) DoorHinge.localRotation = restoreOriginal ? acquiredRotation : closedRotation;
            activeLease = 0;
        }
        public bool TrySetSceneDoorOpen(float progress)
        {
            if (!IsSceneEntryBound || !IsReady || activeLease != 0) return false;
            DoorHinge.localRotation=sceneEntry.ClosedLocalRotation.normalized * Quaternion.Euler(0,DoorOpenDegrees*Mathf.Clamp01(progress),0);
            return true;
        }

        public Vector3 CameraPosition(float progress, Vector3 finalPosition)
        {
            float t=Mathf.Clamp01(progress),u=1f-t;
            return u*u*u*ExteriorCamera.position+3f*u*u*t*ThresholdCamera.position+
                3f*u*t*t*InteriorCamera.position+t*t*t*finalPosition;
        }
        public Vector3 EntryDestination(Vector3 legacyDestination) => IsSceneEntryBound ? sceneEntry.LobbyCamera.position : legacyDestination;
        public Vector3 EntryLookTarget(Vector3 legacyLook) => IsSceneEntryBound ? sceneEntry.LobbyLookTarget.position : legacyLook;
        public float EntryFieldOfView(float legacyValue) => IsSceneEntryBound ? sceneEntry.LobbyFieldOfView : legacyValue;

        public bool MustHoldInLobby(Transform avatar,Vector3 candidateCamera)
        {
            if (!IsSceneEntryBound || !IsReady) return false;
            var room=sceneEntry.SceneRoot;
            Bounds protectedRoom=sceneEntry.ProtectedRoomBounds;
            protectedRoom.Expand(sceneEntry.CameraClearance*2);
            if (avatar != null && protectedRoom.Contains(room.InverseTransformPoint(avatar.position))) return true;
            Vector3 start=room.InverseTransformPoint(sceneEntry.LobbyCamera.position),end=room.InverseTransformPoint(candidateCamera);
            if(protectedRoom.Contains(end)) return true;
            Vector3 offset=end-start;
            return offset.sqrMagnitude>.0001f && protectedRoom.IntersectRay(new Ray(start,offset.normalized),out float distance) && distance<=offset.magnitude;
        }
        public CameraPose LobbyPose => new(sceneEntry.LobbyCamera.position,
            Quaternion.LookRotation(sceneEntry.LobbyLookTarget.position-sceneEntry.LobbyCamera.position,Vector3.up));

        public PersonalSpaceNavigation Navigation
        {
            get
            {
                var nav=IsSceneEntryBound?sceneEntry.SceneRoot.GetComponent<PersonalSpaceNavigation>():null;
                return nav!=null&&nav.Revision==sceneEntry.SceneRevision&&nav.gameObject.activeInHierarchy?nav:null;
            }
        }
        public bool TryFitCameraDestination(CameraPose desired,float fieldOfView,Vector3 focus,out CameraPose pose,out float fittedFieldOfView)
            =>TryFitCameraDestinationCore(desired,fieldOfView,focus,false,out pose,out fittedFieldOfView);
        public bool TryFitWorldCameraDestination(CameraPose desired,float fieldOfView,Vector3 focus,out CameraPose pose,out float fittedFieldOfView)
            =>TryFitCameraDestinationCore(desired,fieldOfView,focus,true,out pose,out fittedFieldOfView);
        private bool TryFitCameraDestinationCore(CameraPose desired,float fieldOfView,Vector3 focus,bool allowOrbit,out CameraPose pose,out float fittedFieldOfView)
        {
            pose=desired;fittedFieldOfView=fieldOfView;var nav=Navigation;
            if(nav==null)return false;
            if(nav.ContainsCamera(desired.Position))return true;
            Vector3 offset=desired.Position-focus;float length=offset.magnitude;
            if(length<.1f)return false;
            // Keep the intended front/overhead view but widen the lens when a
            // bedroom wall leaves less distance than the open living room.
            foreach(float angle in allowOrbit?new[]{0f,-35f,35f,-70f,70f,-90f,90f}:new[]{0f})
            for(int step=angle==0?1:0;step<=24;step++)
            {
                float distance=length*(1-step/28f);if(distance<.3f)break;
                float fov=2*Mathf.Atan(Mathf.Tan(fieldOfView*Mathf.Deg2Rad*.5f)*length/distance)*Mathf.Rad2Deg;
                if(fov>112)break;
                Vector3 candidate=focus+Quaternion.AngleAxis(angle,Vector3.up)*offset*(distance/length);
                if(!nav.ContainsCamera(candidate))continue;
                pose=new CameraPose(candidate,angle==0?desired.Rotation:Quaternion.LookRotation(focus-candidate,Vector3.up));fittedFieldOfView=fov;return true;
            }
            return false;
        }

        public bool ValidateEntryRoute()
        {
            if (!IsSceneEntryBound) return false;
            Bounds opening=sceneEntry.EntryOpeningBounds;
            opening.size=new Vector3(opening.size.x-2*sceneEntry.CameraClearance,opening.size.y-2*sceneEntry.CameraClearance,opening.size.z+.002f);
            if(opening.size.x<=0 || opening.size.y<=0) return false;
            Bounds protectedRoom=sceneEntry.ProtectedRoomBounds;protectedRoom.Expand(sceneEntry.CameraClearance*2);
            for(int step=0;step<=128;step++)
            {
                Vector3 point=sceneEntry.SceneRoot.InverseTransformPoint(CameraPosition(step/128f,sceneEntry.LobbyCamera.position));
                if(protectedRoom.Contains(point) || (sceneEntry.EntryWallBounds.Contains(point) && !opening.Contains(point))) return false;
            }
            return true;
        }
    }
}
