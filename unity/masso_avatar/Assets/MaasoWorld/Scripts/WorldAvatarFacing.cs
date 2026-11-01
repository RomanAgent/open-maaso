using UnityEngine;

namespace Maaso.World
{
    public static class WorldAvatarFacing
    {
        public static Quaternion ResolveCorrection(
            Vector3 leftShoulder,
            Vector3 rightShoulder,
            Vector3 hips,
            Vector3 head)
        {
            Vector3 lateral = rightShoulder - leftShoulder;
            Vector3 up = head - hips;
            Vector3 authoredForward = Vector3.Cross(lateral, up);
            authoredForward.y = 0f;
            if (!IsFinite(authoredForward) ||
                authoredForward.sqrMagnitude <= 0.000001f)
            {
                return Quaternion.identity;
            }

            return Quaternion.FromToRotation(
                authoredForward.normalized,
                Vector3.forward);
        }

        public static bool AlignToRootForward(Transform visualRoot)
        {
            if (visualRoot == null)
            {
                return false;
            }

            Animator animator =
                visualRoot.GetComponentInChildren<Animator>(true);
            if (animator == null || !animator.isHuman)
            {
                return false;
            }

            Transform leftShoulder =
                animator.GetBoneTransform(HumanBodyBones.LeftUpperArm);
            Transform rightShoulder =
                animator.GetBoneTransform(HumanBodyBones.RightUpperArm);
            Transform hips =
                animator.GetBoneTransform(HumanBodyBones.Hips);
            Transform head =
                animator.GetBoneTransform(HumanBodyBones.Head);
            if (leftShoulder == null ||
                rightShoulder == null ||
                hips == null ||
                head == null)
            {
                return false;
            }

            Quaternion correction = ResolveCorrection(
                visualRoot.InverseTransformPoint(leftShoulder.position),
                visualRoot.InverseTransformPoint(rightShoulder.position),
                visualRoot.InverseTransformPoint(hips.position),
                visualRoot.InverseTransformPoint(head.position));
            visualRoot.localRotation *= correction;
            return true;
        }

        private static bool IsFinite(Vector3 value) =>
            IsFinite(value.x) && IsFinite(value.y) && IsFinite(value.z);

        private static bool IsFinite(float value) =>
            !float.IsNaN(value) && !float.IsInfinity(value);
    }
}
