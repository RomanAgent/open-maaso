using UniVRM10;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Captures the SDK's normalized-to-raw rest mapping at activation.
    /// UniGLTF TransformState stays behind the existing VRM bridge assembly;
    /// callers receive only Unity transforms and quaternions.</summary>
    public static class AvatarVrmNormalizedBoneBinding
    {
        public static bool TryCapture(Vrm10Instance instance, Vrm10Runtime runtime,
            HumanBodyBones id, out Transform target, out Quaternion initialLocal,
            out Quaternion initialGlobal)
        {
            target = null;
            initialLocal = Quaternion.identity;
            initialGlobal = Quaternion.identity;
            if (instance == null || runtime == null || runtime.InitPose == null) return false;
            var controls = runtime.ControlRig;
            if (controls != null)
            {
                if (!controls.Bones.TryGetValue(id, out var bone) || bone.ControlBone == null) return false;
                target = bone.ControlBone;
                return true;
            }
            if (!instance.TryGetBoneTransform(id, out var raw) || raw == null ||
                !runtime.InitPose.TryGetValue(raw, out var rest)) return false;
            target = raw;
            initialLocal = rest.LocalRotation;
            initialGlobal = rest.Rotation;
            return true;
        }
    }
}
