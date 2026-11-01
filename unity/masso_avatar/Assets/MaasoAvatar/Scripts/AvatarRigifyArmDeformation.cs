using System.Collections.Generic;
using UniVRM10;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>
    /// Ports the reviewed Joy Rigify arm deformation constraints after UniVRM
    /// has transferred its normalized pose. The source separates the FK joint
    /// frame from the skin's two-segment roll frame; dropping that distinction
    /// leaves the elbow support bones attached to the wrong roll.
    ///
    /// This is a model adapter, not another animation owner. Normalized bones,
    /// shoulder/elbow/wrist positions, forearm/wrist orientation, fingers,
    /// local scales, root, legs, face and task IK remain untouched. Only the raw
    /// upper-arm roll and the two authored deformation segments are corrected;
    /// child joint local transforms compensate for those parent corrections.
    /// </summary>
    [DefaultExecutionOrder(11010)]
    public sealed class AvatarRigifyArmDeformation : MonoBehaviour
    {
        private const float PositionOwnershipTolerance = .000001f;
        private const float RotationOwnershipTolerance = .02f;
        private readonly List<OwnedTransform> owned = new(10);
        private Transform model;
        private Arm left, right;

        public bool Bound => model != null && left != null && right != null;

        private sealed class Arm
        {
            public Transform Shoulder, Upper, UpperMid, Forearm, ForearmMid, Hand;
            public Quaternion UpperFromShoulder, UpperMidRestRoll, ForearmMidRestRoll;
            public float UpperFraction, ForearmFraction;
        }

        private sealed class OwnedTransform
        {
            public Transform Bone;
            public Vector3 BeforePosition, WrittenPosition;
            public Quaternion BeforeRotation, WrittenRotation;
            public bool HasWrite;

            public void Restore()
            {
                if (!HasWrite) return;
                if (Bone != null)
                {
                    // A later explicit owner may have changed either channel.
                    // Return only channels that still contain our own write.
                    if ((Bone.localPosition - WrittenPosition).sqrMagnitude <=
                        PositionOwnershipTolerance * PositionOwnershipTolerance)
                        Bone.localPosition = BeforePosition;
                    if (Quaternion.Angle(Bone.localRotation, WrittenRotation) <= RotationOwnershipTolerance)
                        Bone.localRotation = BeforeRotation;
                }
                HasWrite = false;
            }
        }

        private readonly struct ArmInput
        {
            public readonly Vector3 ShoulderPoint, ElbowPoint, WristPoint;
            public readonly Quaternion ShoulderRotation, ForearmRotation, HandRotation;

            public ArmInput(Arm arm)
            {
                ShoulderPoint = arm.Upper.position;
                ElbowPoint = arm.Forearm.position;
                WristPoint = arm.Hand.position;
                ShoulderRotation = arm.Shoulder.rotation;
                ForearmRotation = arm.Forearm.rotation;
                HandRotation = arm.Hand.rotation;
            }
        }

        /// <summary>
        /// Bind at model activation. Calibrate from the actual skin inverse bind
        /// matrices (Joy's authored A bind), never the imported current T pose or
        /// an already animated pose. Non-Joy/custom rigs receive no writes.
        /// </summary>
        public bool Bind(Transform modelRoot)
        {
            Reset();
            if (modelRoot == null || modelRoot.GetComponent<Vrm10Instance>() == null) return false;
            SkinnedMeshRenderer body = null;
            foreach (var renderer in modelRoot.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                Mesh mesh = renderer.sharedMesh;
                if (renderer.name != "Joy_body" || mesh == null ||
                    mesh.GetBlendShapeIndex("fix_upperarm.Z_rot.L") < 0 ||
                    mesh.GetBlendShapeIndex("fix_upperarm.Z_rot.R") < 0 ||
                    mesh.GetBlendShapeIndex("fix_upperarm.X_rot.L") < 0 ||
                    mesh.GetBlendShapeIndex("fix_upperarm.X_rot.R") < 0) continue;
                if (body != null) return false;
                body = renderer;
            }
            if (body == null) return false;
            Transform[] skinBones = body.bones;
            Matrix4x4[] bindposes = body.sharedMesh.bindposes;
            if (skinBones.Length != bindposes.Length) return false;
            var named = new Dictionary<string, Transform>();
            var rest = new Dictionary<Transform, Matrix4x4>();
            Matrix4x4 skinToModel = modelRoot.worldToLocalMatrix * body.transform.localToWorldMatrix;
            for (int index = 0; index < skinBones.Length; index++)
            {
                Transform bone = skinBones[index];
                if (bone == null || named.ContainsKey(bone.name)) return false;
                named.Add(bone.name, bone);
                Matrix4x4 pose = skinToModel * bindposes[index].inverse;
                if (!Finite(pose)) return false;
                rest.Add(bone, pose);
            }
            Arm a = BuildArm("L", named, rest), b = BuildArm("R", named, rest);
            if (a == null || b == null) return false;
            model = modelRoot;
            left = a;
            right = b;
            AddOwned(a);
            AddOwned(b);
            return true;
        }

        private static Arm BuildArm(string side, Dictionary<string, Transform> named,
            Dictionary<Transform, Matrix4x4> rest)
        {
            Transform Bone(string stem) => named.TryGetValue(stem + "." + side, out var bone) ? bone : null;
            Transform Mid(string stem) => named.TryGetValue(stem + "." + side + ".001", out var bone) ? bone : null;
            var arm = new Arm { Shoulder = Bone("DEF-shoulder"), Upper = Bone("DEF-upper_arm"),
                UpperMid = Mid("DEF-upper_arm"), Forearm = Bone("DEF-forearm"),
                ForearmMid = Mid("DEF-forearm"), Hand = Bone("DEF-hand") };
            if (arm.Shoulder == null || arm.Upper == null || arm.UpperMid == null ||
                arm.Forearm == null || arm.ForearmMid == null || arm.Hand == null ||
                arm.Upper.parent != arm.Shoulder || arm.UpperMid.parent != arm.Upper ||
                arm.Forearm.parent != arm.UpperMid || arm.ForearmMid.parent != arm.Forearm ||
                arm.Hand.parent != arm.ForearmMid) return null;
            Matrix4x4 s = rest[arm.Shoulder], u = rest[arm.Upper], um = rest[arm.UpperMid],
                f = rest[arm.Forearm], fm = rest[arm.ForearmMid], h = rest[arm.Hand];
            Vector3 upperDirection = f.GetColumn(3) - u.GetColumn(3),
                forearmDirection = h.GetColumn(3) - f.GetColumn(3);
            float upperLength = upperDirection.magnitude, forearmLength = forearmDirection.magnitude;
            if (upperLength < .05f || forearmLength < .05f) return null;
            Quaternion uq = Rotation(u), fq = Rotation(f), hq = Rotation(h);
            // This profile's source Damped Track axis is bone-local +Y. Fail
            // closed on a similarly named rig with a different bind convention.
            if (Vector3.Dot(uq * Vector3.up, upperDirection.normalized) < .999f ||
                Vector3.Dot(fq * Vector3.up, forearmDirection.normalized) < .999f) return null;
            arm.UpperFraction = Vector3.Dot((Vector3)um.GetColumn(3) - (Vector3)u.GetColumn(3), upperDirection) /
                upperDirection.sqrMagnitude;
            arm.ForearmFraction = Vector3.Dot((Vector3)fm.GetColumn(3) - (Vector3)f.GetColumn(3), forearmDirection) /
                forearmDirection.sqrMagnitude;
            if (arm.UpperFraction < .45f || arm.UpperFraction > .55f ||
                arm.ForearmFraction < .45f || arm.ForearmFraction > .55f) return null;
            arm.UpperFromShoulder = Quaternion.Inverse(Rotation(s)) * uq;
            // Each MCH midpoint is Copy Transforms(first), Copy Transforms(next,
            // influence .5), then Damped Track(+Y). Its tweak child retains an
            // authored LOCAL rest roll: the forearm's ~4.466 degrees matters.
            arm.UpperMidRestRoll = Quaternion.Inverse(TrackY(Quaternion.Slerp(uq, fq, .5f), upperDirection)) * Rotation(um);
            arm.ForearmMidRestRoll = Quaternion.Inverse(TrackY(Quaternion.Slerp(fq, hq, .5f), forearmDirection)) * Rotation(fm);
            return arm;
        }

        private void AddOwned(Arm arm)
        {
            owned.Add(new OwnedTransform { Bone = arm.Upper });
            owned.Add(new OwnedTransform { Bone = arm.UpperMid });
            owned.Add(new OwnedTransform { Bone = arm.Forearm });
            owned.Add(new OwnedTransform { Bone = arm.ForearmMid });
            owned.Add(new OwnedTransform { Bone = arm.Hand });
        }

        /// <summary>After VRM.Process, before skinning. No allocations per frame.</summary>
        public void ApplyAfterVrm()
        {
            RestoreBeforeAnimation();
            if (!Bound || !isActiveAndEnabled) return;
            if (left.Hand == null || right.Hand == null) { Reset(); return; }
            var a = new ArmInput(left);
            var b = new ArmInput(right);
            Apply(left, a, 0);
            Apply(right, b, 5);
        }

        private void Apply(Arm arm, ArmInput input, int first)
        {
            Vector3 upperDirection = input.ElbowPoint - input.ShoulderPoint,
                forearmDirection = input.WristPoint - input.ElbowPoint;
            if (!Finite(upperDirection) || !Finite(forearmDirection) ||
                upperDirection.sqrMagnitude < .0001f || forearmDirection.sqrMagnitude < .0001f) return;
            Quaternion upper = TrackY(input.ShoulderRotation * arm.UpperFromShoulder, upperDirection);
            Quaternion upperMid = TrackY(TrackY(Quaternion.Slerp(upper, input.ForearmRotation, .5f), upperDirection) *
                arm.UpperMidRestRoll, upperDirection);
            Quaternion forearmMid = TrackY(TrackY(Quaternion.Slerp(input.ForearmRotation, input.HandRotation, .5f),
                forearmDirection) * arm.ForearmMidRestRoll, forearmDirection);
            WriteWorld(first, input.ShoulderPoint, upper);
            WriteWorld(first + 1, Vector3.LerpUnclamped(input.ShoulderPoint, input.ElbowPoint, arm.UpperFraction), upperMid);
            // Compensate each mapped child after changing its skinning parent.
            // Its exact world joint pose and all hand/finger descendants survive.
            WriteWorld(first + 2, input.ElbowPoint, input.ForearmRotation);
            WriteWorld(first + 3, Vector3.LerpUnclamped(input.ElbowPoint, input.WristPoint, arm.ForearmFraction), forearmMid);
            WriteWorld(first + 4, input.WristPoint, input.HandRotation);
        }

        private void WriteWorld(int index, Vector3 position, Quaternion rotation)
        {
            OwnedTransform item = owned[index];
            item.BeforePosition = item.Bone.localPosition;
            item.BeforeRotation = item.Bone.localRotation;
            item.Bone.SetPositionAndRotation(position, rotation);
            item.WrittenPosition = item.Bone.localPosition;
            item.WrittenRotation = item.Bone.localRotation;
            item.HasWrite = true;
        }

        /// <summary>Before Animator/VRM writes a new frame, or when released.</summary>
        public void RestoreBeforeAnimation()
        {
            for (int index = owned.Count - 1; index >= 0; index--) owned[index].Restore();
        }

        public void Reset()
        {
            RestoreBeforeAnimation();
            owned.Clear();
            model = null;
            left = right = null;
        }

        private void Update() => RestoreBeforeAnimation();
        private void LateUpdate() => ApplyAfterVrm();
        private void OnDisable() => RestoreBeforeAnimation();
        private void OnDestroy() => Reset();

        private static Quaternion TrackY(Quaternion value, Vector3 direction) =>
            Quaternion.FromToRotation(value * Vector3.up, direction.normalized) * value;
        private static Quaternion Rotation(Matrix4x4 value) =>
            Quaternion.LookRotation(value.GetColumn(2), value.GetColumn(1));
        private static bool Finite(Vector3 value) => Finite(value.x) && Finite(value.y) && Finite(value.z);
        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
        private static bool Finite(Matrix4x4 value)
        {
            for (int index = 0; index < 16; index++) if (!Finite(value[index])) return false;
            return Mathf.Abs(value.determinant) > .000001f;
        }
    }
}
