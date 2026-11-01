using System;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Host-authored metadata referencing the one entry already in the
    /// room. It contains no prefab source and cannot create a replacement door.</summary>
    [Serializable]
    public sealed class LoginDoorwaySceneBinding
    {
        public string EntryId = "main_entry";
        public string SceneRevision;
        public Transform SceneRoot;
        public Transform DoorHinge, DoorLeaf, FrameRoot;
        public Transform ExteriorCamera, ThresholdCamera, InteriorCamera, DoorLookTarget;
        public Transform LobbyCamera, LobbyLookTarget;
        public Quaternion ClosedLocalRotation = Quaternion.identity;
        public float DoorOpenDegrees = -100f;
        public float LobbyFieldOfView = 58f;
        public float CameraClearance = .08f;
        // All bounds are in SceneRoot-local Unity metres, not Blender axes.
        public Bounds EntryWallBounds = new(new Vector3(0,1.6f,4.1f),new Vector3(8,3.2f,.2f));
        public Bounds EntryOpeningBounds = new(new Vector3(2.5f,1.185f,4.1f),new Vector3(1.02f,2.37f,.2f));
        // Required from the published room metadata. Never infer a bedroom
        // quadrant or reuse a previous layout's protected volume.
        public Bounds ProtectedRoomBounds;

        public bool IsValid(Transform bindingOwner)
        {
            if (SceneRoot == null || bindingOwner == null || !Owned(bindingOwner) ||
                string.IsNullOrWhiteSpace(EntryId) || EntryId.Length > 128 ||
                string.IsNullOrWhiteSpace(SceneRevision) || SceneRevision.Length > 128 ||
                !Owned(DoorHinge) || !Owned(DoorLeaf) || !Owned(FrameRoot) ||
                DoorLeaf == DoorHinge || !DoorLeaf.IsChildOf(DoorHinge) || FrameRoot.IsChildOf(DoorHinge) ||
                !Owned(ExteriorCamera) || !Owned(ThresholdCamera) || !Owned(InteriorCamera) ||
                !Owned(DoorLookTarget) || !Owned(LobbyCamera) || !Owned(LobbyLookTarget) ||
                !Finite(DoorOpenDegrees) || Mathf.Abs(DoorOpenDegrees) < 45f || Mathf.Abs(DoorOpenDegrees) > 120f ||
                !Finite(LobbyFieldOfView) || LobbyFieldOfView < 25 || LobbyFieldOfView > 100 ||
                !Finite(CameraClearance) || CameraClearance < .02f || CameraClearance > .3f ||
                !ValidBounds(EntryWallBounds) || !ValidBounds(EntryOpeningBounds) || !ValidBounds(ProtectedRoomBounds) ||
                !Finite(ClosedLocalRotation.x) || !Finite(ClosedLocalRotation.y) ||
                !Finite(ClosedLocalRotation.z) || !Finite(ClosedLocalRotation.w) ||
                !FinitePosition(ExteriorCamera) || !FinitePosition(ThresholdCamera) || !FinitePosition(InteriorCamera) ||
                !FinitePosition(DoorLookTarget) || !FinitePosition(LobbyCamera) || !FinitePosition(LobbyLookTarget) ||
                ClosedLocalRotation.x*ClosedLocalRotation.x+ClosedLocalRotation.y*ClosedLocalRotation.y+
                    ClosedLocalRotation.z*ClosedLocalRotation.z+ClosedLocalRotation.w*ClosedLocalRotation.w < .5f) return false;
            return (LobbyLookTarget.position-LobbyCamera.position).sqrMagnitude > .01f &&
                (DoorLookTarget.position-ExteriorCamera.position).sqrMagnitude > .01f;
        }

        private bool Owned(Transform value) => value != null && (value == SceneRoot || value.IsChildOf(SceneRoot));
        private static bool FinitePosition(Transform value) => Finite(value.position.x) && Finite(value.position.y) && Finite(value.position.z);
        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
        private static bool ValidBounds(Bounds bounds) =>
            Finite(bounds.center.x) && Finite(bounds.center.y) && Finite(bounds.center.z) &&
            Finite(bounds.size.x) && Finite(bounds.size.y) && Finite(bounds.size.z) &&
            bounds.size.x > 0 && bounds.size.y > 0 && bounds.size.z > 0;
    }
}
