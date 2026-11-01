using UniVRM10;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>
    /// Keeps body Humanoid animation from adding a second mouth opening when
    /// the VRM expression system already owns vowels. Apply before VRM.Process:
    /// its legitimate morph and node-transform expressions are applied afterward.
    /// </summary>
    public sealed class AvatarVrmJawOwnership
    {
        private Vrm10Instance instance;
        private Transform rawJaw;
        private Transform normalizedJaw;
        private Quaternion neutralRotation;

        public bool OwnsJaw => instance != null && rawJaw != null;

        public void Bind(Vrm10Instance value)
        {
            instance = null;
            rawJaw = null;
            normalizedJaw = null;
            if (value == null || value.Vrm == null || value.Vrm.Expression == null ||
                !HasVowelMotion(value) ||
                !value.TryGetBoneTransform(HumanBodyBones.Jaw, out Transform jaw) || jaw == null)
                return;

            Vrm10Runtime runtime = value.Runtime;
            // The imported rest pose is authoritative. Do not record a pose
            // already changed by Animator.Rebind as the model's neutral mouth.
            if (runtime.InitPose == null || !runtime.InitPose.TryGetValue(jaw, out var initial))
                return;

            instance = value;
            rawJaw = jaw;
            neutralRotation = initial.LocalRotation;
            normalizedJaw = runtime.ControlRig?.GetBoneTransform(HumanBodyBones.Jaw);
        }

        public void Apply()
        {
            if (!OwnsJaw) return;
            rawJaw.localRotation = neutralRotation;
            // UniVRM's normalized control rig maps identity onto the imported
            // raw-bone rotation. Leaving Animator's jaw on that rig would undo
            // the raw-bone correction during the following VRM.Process call.
            if (normalizedJaw != null) normalizedJaw.localRotation = Quaternion.identity;
        }

        private static bool HasVowelMotion(Vrm10Instance value)
        {
            var expressions = value.Vrm.Expression;
            return HasMotion(expressions.Aa) || HasMotion(expressions.Ih) ||
                HasMotion(expressions.Ou) || HasMotion(expressions.Ee) || HasMotion(expressions.Oh);
        }

        private static bool HasMotion(VRM10Expression expression) => expression != null &&
            ((expression.MorphTargetBindings?.Length ?? 0) > 0 ||
             (expression.NodeTransformBindings?.Length ?? 0) > 0);
    }
}
