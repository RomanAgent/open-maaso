using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Bounded analytic two-bone geometry, shared in principle with the existing
    /// furniture contact solver. No Animator evaluation, owner, root or finger writes.</summary>
    public static class AvatarArmIk
    {
        public static bool TrySolve(Vector3 shoulder, Vector3 elbow, Vector3 wrist,
            Vector3 target, Vector3 bendHint, out Vector3 joint, out Vector3 end)
        {
            joint = elbow; end = wrist;
            if (!Finite(shoulder) || !Finite(elbow) || !Finite(wrist) || !Finite(target) || !Finite(bendHint)) return false;
            float a = Vector3.Distance(shoulder, elbow), b = Vector3.Distance(elbow, wrist);
            Vector3 offset = target - shoulder;
            if (a < .0001f || b < .0001f || offset.sqrMagnitude < .00000001f) return false;
            float epsilon = Mathf.Min(a, b) * .005f;
            float distance = Mathf.Clamp(offset.magnitude, Mathf.Abs(a - b) + epsilon, a + b - epsilon);
            Vector3 axis = offset.normalized;
            Vector3 bend = Vector3.ProjectOnPlane(bendHint, axis);
            if (bend.sqrMagnitude < .00000001f) bend = Vector3.ProjectOnPlane(elbow - shoulder, axis);
            if (bend.sqrMagnitude < .00000001f)
                bend = Vector3.Cross(axis, Mathf.Abs(axis.y) < .9f ? Vector3.up : Vector3.right);
            bend.Normalize();
            float along = (a * a - b * b + distance * distance) / (2f * distance);
            joint = shoulder + axis * along + bend * Mathf.Sqrt(Mathf.Max(0f, a * a - along * along));
            end = shoulder + axis * distance;
            return Finite(joint) && Finite(end);
        }

        public static bool CanApply(Transform upper, Transform lower, Transform hand,
            Vector3 target, Vector3 bendHint, float maximumCorrectionDegrees = 60f) =>
            TryRotations(upper, lower, hand, target, bendHint, maximumCorrectionDegrees, out _, out _);

        public static bool Apply(Transform upper, Transform lower, Transform hand,
            Vector3 target, Vector3 bendHint, float maximumCorrectionDegrees = 60f)
        {
            if (!TryRotations(upper, lower, hand, target, bendHint, maximumCorrectionDegrees, out var upperAfter, out var lowerAfter)) return false;
            Quaternion wrist = hand.rotation;
            upper.rotation = upperAfter; lower.rotation = lowerAfter; hand.rotation = wrist;
            return true;
        }

        private static bool TryRotations(Transform upper, Transform lower, Transform hand,
            Vector3 target, Vector3 bendHint, float maximumCorrectionDegrees, out Quaternion upperAfter, out Quaternion lowerAfter)
        {
            upperAfter = lowerAfter = Quaternion.identity;
            if (upper == null || lower == null || hand == null || !Finite(maximumCorrectionDegrees) || maximumCorrectionDegrees <= 0f ||
                !TrySolve(upper.position, lower.position, hand.position, target, bendHint, out Vector3 joint, out Vector3 end)) return false;
            Quaternion upperBefore = upper.rotation, lowerBefore = lower.rotation;
            upperAfter = Quaternion.FromToRotation(lower.position - upper.position, joint - upper.position) * upperBefore;
            Quaternion parentDelta = upperAfter * Quaternion.Inverse(upperBefore);
            Vector3 predictedWrist = joint + parentDelta * (hand.position - lower.position);
            lowerAfter = Quaternion.FromToRotation(predictedWrist - joint, end - joint) * parentDelta * lowerBefore;
            return Quaternion.Angle(upperBefore, upperAfter) <= maximumCorrectionDegrees &&
                Quaternion.Angle(lowerBefore, lowerAfter) <= maximumCorrectionDegrees;
        }

        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
        private static bool Finite(Vector3 value) => Finite(value.x) && Finite(value.y) && Finite(value.z);
    }
}
