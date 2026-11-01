using System;
using System.Collections.Generic;
using UniVRM10;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Low-priority, bounded free-gesture arm clearance. Body/head/forearm/palm
    /// envelopes are calibrated ONCE from actual readable skin bind poses and weights.
    /// Per frame uses only cached capsules, bone points and analytic two-bone geometry;
    /// never BakeMesh, physics components, Animator evaluation, root/leg/finger writes.
    /// Restore before Animator; apply after inertia/micro-motion and before task/gaze/VRM.
    /// Caller must exclude explicit actions, contacts, walking, presence and background work.
    /// This guards sampled envelopes, not arbitrary garments or all possible intersections.</summary>
    public sealed class AvatarFreeGestureCollisionGuard
    {
        private const float MarginFraction = .004f;
        public const float MaximumCorrectionDegrees = 24f;
        public const float MaximumCorrectionSpeedDegrees = 60f;
        private const float CorrectionResponseSeconds = .12f;
        private const float ContactReleaseGraceSeconds = .15f;
        private float previousFrameAt = float.NaN;
        private readonly List<Owned> owned = new(6);
        private Transform root, hips, torsoTop, head;
        private Animator animator;
        private UnityEngine.Avatar avatar;
        private Arm left, right;
        private float bodyRadius, headRadius, frameScale, frameMargin;
        private Capsule frameBody, frameHead;
        private Vector3 headCenterLocal;
        public bool Bound => root != null && left != null && right != null;
        public bool HasOwnedWrites { get { foreach (Owned item in owned) if (item.HasWrite) return true; return false; } }
        public int CalibrationVertexCount { get; private set; }
        public string BindingDiagnostic { get; private set; } = "unbound";
        public int CorrectedArms { get; private set; }
        public bool Unresolved { get; private set; }
        public float LastMinimumClearance { get; private set; }
        public float BodyRadius => Bound ? bodyRadius * RootScale : 0f;
        public float HeadRadius => Bound ? headRadius * RootScale : 0f;
        public Vector3 TorsoStart => hips != null ? hips.position : Vector3.zero;
        public Vector3 TorsoEnd => torsoTop != null ? torsoTop.position : Vector3.zero;
        public Vector3 HeadCenter => head != null ? head.TransformPoint(headCenterLocal) : Vector3.zero;
        private float RootScale { get { Vector3 scale = root.lossyScale; return Mathf.Max(Mathf.Abs(scale.x), Mathf.Abs(scale.y), Mathf.Abs(scale.z)); } }

        private sealed class Owned
        {
            public Transform Bone;
            public Quaternion Source, Written;
            public Quaternion Correction = Quaternion.identity, Target = Quaternion.identity;
            public bool HasWrite;
        }
        private sealed class Arm
        {
            public Transform Upper, Lower, Hand, Middle;
            public float Radius, PalmRadius;
            public int First;
            public Vector3 Side;
            public Transform[] Tips;
            public Vector3[] TipOffsets;
            public float LastContactAt = float.NegativeInfinity;
        }
        private readonly struct Capsule
        {
            public readonly Vector3 A, B;
            public readonly float Radius;
            public Capsule(Vector3 a, Vector3 b, float radius) { A = a; B = b; Radius = radius; }
        }

        public bool Bind(Transform modelRoot, Animator value)
        {
            if (Bound && root == modelRoot && animator == value && value != null && value.avatar == avatar) return true;
            Reset(); owned.Clear(); root = null; animator = null; avatar = null; left = right = null;
            CalibrationVertexCount = 0; BindingDiagnostic = "calibrating";
            if (modelRoot == null || value == null || !value.isHuman || value.avatar == null) return Fail("humanoid_unavailable");
            Transform Bone(HumanBodyBones id) => value.GetBoneTransform(id);
            hips = Bone(HumanBodyBones.Hips); torsoTop = Bone(HumanBodyBones.Neck) ?? Bone(HumanBodyBones.UpperChest) ?? Bone(HumanBodyBones.Chest);
            head = Bone(HumanBodyBones.Head);
            Arm a = BuildArm(value, true), b = BuildArm(value, false);
            if (hips == null || torsoTop == null || head == null || a == null || b == null || !head.IsChildOf(modelRoot)) return Fail("mapped_bones_unavailable");
            var vrm = modelRoot.GetComponentInChildren<Vrm10Instance>(true);
            Transform Raw(HumanBodyBones id) => vrm != null ? vrm.Humanoid.GetBoneTransform(id) : Bone(id);
            var categories = new Dictionary<Transform, int>();
            void Category(HumanBodyBones id, int kind) { Transform t = Raw(id); if (t != null) categories[t] = kind; }
            foreach (HumanBodyBones id in new[] { HumanBodyBones.Hips, HumanBodyBones.Spine, HumanBodyBones.Chest, HumanBodyBones.UpperChest, HumanBodyBones.Neck }) Category(id, 1);
            Category(HumanBodyBones.Head, 2);
            Category(HumanBodyBones.LeftUpperArm, 0); Category(HumanBodyBones.RightUpperArm, 0);
            Category(HumanBodyBones.LeftLowerArm, 3); Category(HumanBodyBones.RightLowerArm, 4);
            Category(HumanBodyBones.LeftHand, 5); Category(HumanBodyBones.RightHand, 6);
            Category(HumanBodyBones.LeftUpperLeg, 0); Category(HumanBodyBones.RightUpperLeg, 0);
            // Finger descendants are point probes, not a palm-radius fit.
            foreach (HumanBodyBones id in Enum.GetValues(typeof(HumanBodyBones)))
                if (id.ToString().Contains("Proximal") || id.ToString().Contains("Intermediate") || id.ToString().Contains("Distal")) Category(id, 0);
            var points = new List<Vector3>[7]; for (int i = 0; i < points.Length; i++) points[i] = new List<Vector3>();
            var rest = new Dictionary<Transform, Matrix4x4>();
            foreach (var skin in modelRoot.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                Mesh mesh = skin.sharedMesh;
                if (mesh == null || !mesh.isReadable) continue;
                Transform[] skinBones = skin.bones; Matrix4x4[] poses = mesh.bindposes;
                if (skinBones.Length != poses.Length) continue;
                Vector3[] vertices = mesh.vertices; BoneWeight[] weights = mesh.boneWeights;
                if (vertices.Length != weights.Length) continue;
                Matrix4x4 skinToModel = modelRoot.worldToLocalMatrix * skin.transform.localToWorldMatrix;
                var kinds = new int[skinBones.Length];
                for (int i = 0; i < skinBones.Length; i++)
                {
                    Transform bone = skinBones[i]; kinds[i] = 0;
                    if (bone == null) continue;
                    if (!rest.ContainsKey(bone)) rest.Add(bone, skinToModel * poses[i].inverse);
                    for (Transform ancestor = bone; ancestor != null; ancestor = ancestor.parent)
                        if (categories.TryGetValue(ancestor, out int kind)) { kinds[i] = kind; break; }
                }
                for (int i = 0; i < vertices.Length; i++)
                {
                    BoneWeight w = weights[i]; int index = w.boneIndex0; float weight = w.weight0;
                    if (w.weight1 > weight) { weight = w.weight1; index = w.boneIndex1; }
                    if (w.weight2 > weight) { weight = w.weight2; index = w.boneIndex2; }
                    if (w.weight3 > weight) { weight = w.weight3; index = w.boneIndex3; }
                    if (weight < .35f || index < 0 || index >= kinds.Length || kinds[index] == 0) continue;
                    Vector3 point = skinToModel.MultiplyPoint3x4(vertices[i]);
                    if (!Finite(point)) continue;
                    points[kinds[index]].Add(point); CalibrationVertexCount++;
                }
            }
            Vector3 RestPoint(HumanBodyBones id) { Transform bone = Raw(id); return bone != null && rest.TryGetValue(bone, out var matrix) ? (Vector3)matrix.GetColumn(3) : new Vector3(float.NaN, 0, 0); }
            Vector3 restHips = RestPoint(HumanBodyBones.Hips), restTop = RestPoint(HumanBodyBones.Neck);
            if (!Finite(restTop)) restTop = RestPoint(HumanBodyBones.Chest);
            if (points[1].Count < 16 || points[2].Count < 8 || !Finite(restHips) || !Finite(restTop)) return Fail("body_or_head_bind_probes_unavailable");
            float radius = Radius(points[1], restHips, restTop);
            Bounds headBounds = new(points[2][0], Vector3.zero); foreach (Vector3 point in points[2]) headBounds.Encapsulate(point);
            float skull = 0f; foreach (Vector3 point in points[2]) skull = Mathf.Max(skull, Vector3.Distance(point, headBounds.center));
            Matrix4x4 headRest;
            if (Raw(HumanBodyBones.Head) == head && rest.TryGetValue(head, out headRest)) { }
            else if (!TryHumanoidRestMatrix(value, modelRoot, head, out headRest)) return Fail("normalized_head_rest_unavailable");
            float span = Vector3.Distance(restHips, restTop);
            if (!Finite(radius) || !Finite(skull) || radius < span * .08f || radius > span * .75f || skull < span * .08f || skull > span * .6f) return Fail("body_or_head_envelope_out_of_bounds");
            a.Radius = Radius(points[3], RestPoint(HumanBodyBones.LeftLowerArm), RestPoint(HumanBodyBones.LeftHand));
            b.Radius = Radius(points[4], RestPoint(HumanBodyBones.RightLowerArm), RestPoint(HumanBodyBones.RightHand));
            a.PalmRadius = Radius(points[5], RestPoint(HumanBodyBones.LeftHand), RestPoint(HumanBodyBones.LeftMiddleProximal));
            b.PalmRadius = Radius(points[6], RestPoint(HumanBodyBones.RightHand), RestPoint(HumanBodyBones.RightMiddleProximal));
            foreach (Arm arm in new[] { a, b }) if (!Finite(arm.Radius) || !Finite(arm.PalmRadius) || arm.Radius < span * .01f || arm.PalmRadius < span * .01f) return Fail("arm_or_palm_bind_probes_unavailable");
            Vector3 restCenter = (restHips + restTop) * .5f;
            a.Side = Vector3.ProjectOnPlane(RestPoint(HumanBodyBones.LeftUpperArm) - restCenter, Vector3.up).normalized;
            b.Side = Vector3.ProjectOnPlane(RestPoint(HumanBodyBones.RightUpperArm) - restCenter, Vector3.up).normalized;
            if (!Finite(a.Side) || !Finite(b.Side) || a.Side.sqrMagnitude < .5f || b.Side.sqrMagnitude < .5f) return Fail("arm_side_bind_frame_unavailable");
            root = modelRoot; animator = value; avatar = value.avatar; left = a; right = b;
            bodyRadius = radius; headRadius = skull; headCenterLocal = headRest.inverse.MultiplyPoint3x4(headBounds.center);
            AddOwned(a); AddOwned(b); BindingDiagnostic = "calibrated"; return true;
        }

        private bool Fail(string reason) { BindingDiagnostic = reason; return false; }
        private static Arm BuildArm(Animator value, bool left)
        {
            Transform Bone(HumanBodyBones id) => value.GetBoneTransform(id);
            var arm = new Arm { Upper = Bone(left ? HumanBodyBones.LeftUpperArm : HumanBodyBones.RightUpperArm),
                Lower = Bone(left ? HumanBodyBones.LeftLowerArm : HumanBodyBones.RightLowerArm),
                Hand = Bone(left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand),
                Middle = Bone(left ? HumanBodyBones.LeftMiddleProximal : HumanBodyBones.RightMiddleProximal), Side = left ? Vector3.left : Vector3.right };
            if (arm.Upper == null || arm.Lower == null || arm.Hand == null || arm.Middle == null) return null;
            var tips = new List<Transform>();
            foreach (HumanBodyBones id in Enum.GetValues(typeof(HumanBodyBones)))
                if (id.ToString().StartsWith(left ? "Left" : "Right", StringComparison.Ordinal) && id.ToString().EndsWith("Distal", StringComparison.Ordinal))
                { Transform tip = Bone(id); if (tip != null) tips.Add(tip); }
            arm.Tips = tips.ToArray(); arm.TipOffsets = new Vector3[tips.Count]; return arm;
        }
        private void AddOwned(Arm arm)
        {
            arm.First = owned.Count;
            foreach (Transform bone in new[] { arm.Upper, arm.Lower, arm.Hand }) owned.Add(new Owned { Bone = bone });
        }
        private static float Radius(List<Vector3> points, Vector3 a, Vector3 b)
        {
            if (points.Count < 4 || !Finite(a) || !Finite(b) || (a - b).sqrMagnitude < .000001f) return float.NaN;
            float radius = 0f; foreach (Vector3 point in points) radius = Mathf.Max(radius, Vector3.Distance(point, Closest(point, a, b)));
            return radius;
        }
        private static bool TryHumanoidRestMatrix(Animator value, Transform modelRoot, Transform bone, out Matrix4x4 matrix)
        {
            var skeleton = new Dictionary<string, SkeletonBone>();
            foreach (SkeletonBone item in value.avatar.humanDescription.skeleton) if (!skeleton.ContainsKey(item.name)) skeleton.Add(item.name, item);
            matrix = Matrix4x4.identity;
            if (!skeleton.ContainsKey(bone.name)) return false;
            for (Transform item = bone; item != modelRoot; item = item.parent)
            {
                if (item == null) return false;
                Matrix4x4 local = skeleton.TryGetValue(item.name, out var rest) ? Matrix4x4.TRS(rest.position, rest.rotation, rest.scale) :
                    Matrix4x4.TRS(item.localPosition, item.localRotation, item.localScale);
                matrix = local * matrix;
            }
            return Finite(matrix.GetColumn(3));
        }

        public void RestoreBeforeAnimation()
        {
            for (int i = owned.Count - 1; i >= 0; i--)
            {
                Owned item = owned[i];
                if (item.HasWrite && item.Bone != null && Quaternion.Angle(item.Bone.localRotation, item.Written) < .025f)
                    item.Bone.localRotation = item.Source;
                item.HasWrite = false;
            }
        }
        /// <returns>Whether calibrated sampled envelopes are clear after the bounded correction.</returns>
        public bool Apply(bool allowed) => ApplyAt(Time.realtimeSinceStartup, allowed);

        /// <summary>Continuous corrective offsets, never a per-frame pose replacement.
        /// Contact hysteresis and speed limits operate AFTER the ordinary pose smoother.
        /// Unresolved clearance is diagnostic; it must not restart speech playback.</summary>
        public bool ApplyAt(float now, bool allowed)
        {
            RestoreBeforeAnimation(); CorrectedArms = 0; Unresolved = false; LastMinimumClearance = float.PositiveInfinity;
            if (!allowed || !Bound || animator == null || !animator.isActiveAndEnabled || !Finite(now))
            { ResetCorrections(); return true; }
            float delta = Finite(previousFrameAt) ? now - previousFrameAt : 1f / 60f;
            if (delta < 0f || delta > .25f) { ResetCorrections(); delta = 1f / 60f; }
            previousFrameAt = now;
            PrepareFrame();
            float leftClearance = Correct(left, now, Mathf.Min(delta, .05f));
            float rightClearance = Correct(right, now, Mathf.Min(delta, .05f));
            LastMinimumClearance = Mathf.Min(leftClearance, rightClearance);
            Unresolved = LastMinimumClearance < -.001f * frameScale;
            return !Unresolved;
        }

        private float Correct(Arm arm, float now, float delta)
        {
            Vector3 wrist = arm.Hand.position, elbow = arm.Lower.position, shoulder = arm.Upper.position;
            Quaternion wristRotation = arm.Hand.rotation;
            for (int i = 0; i < arm.Tips.Length; i++) arm.TipOffsets[i] = arm.Tips[i].position - wrist;
            Vector3 palmOffset = arm.Middle.position - wrist;
            float initial = Clearance(arm, elbow, wrist, palmOffset);
            for (int i = arm.First; i < arm.First + 3; i++) owned[i].Source = owned[i].Bone.localRotation;
            if (initial < 0f)
            {
                arm.LastContactAt = now;
                Vector3 side = root.TransformDirection(arm.Side).normalized, forward = root.forward, up = root.up;
                Vector3 bend = Vector3.ProjectOnPlane(elbow - shoulder, wrist - shoulder);
                if (bend.sqrMagnitude < .000001f) bend = side;
                float reach = Vector3.Distance(shoulder, elbow) + Vector3.Distance(elbow, wrist);
                float sourceElbow = Vector3.Angle(shoulder - elbow, wrist - elbow);
                Vector3 best = wrist, bestBend = bend; float bestClearance = initial, bestMovement = float.PositiveInfinity;
                for (int ring = 1; ring <= 9; ring++)
                {
                    float distance = reach * (.05f * ring);
                    for (int direction = 0; direction < 5; direction++)
                    {
                        Vector3 offset = direction switch { 0 => side, 1 => forward, 2 => (side + forward).normalized,
                            3 => (side + up * .65f).normalized, _ => (side - up * .65f).normalized };
                        Vector3 target = wrist + offset * distance;
                        Vector3 hint = bend.normalized + side * .3f;
                        if (!AvatarArmIk.TrySolve(shoulder, elbow, wrist, target, hint, out Vector3 joint, out Vector3 end)) continue;
                        // A clearance correction must not fold an ordinary elbow
                        // sharply or amplify an already tightly authored bend.
                        if (Vector3.Angle(shoulder - joint, end - joint) < Mathf.Min(55f, sourceElbow)) continue;
                        if (!AvatarArmIk.CanApply(arm.Upper, arm.Lower, arm.Hand, end, hint, MaximumCorrectionDegrees)) continue;
                        float clearance = Clearance(arm, joint, end, palmOffset);
                        float movement = Vector3.Distance(end, wrist);
                        if (clearance >= 0f && movement < bestMovement || bestClearance < 0f && clearance > bestClearance)
                        { best = end; bestBend = hint; bestClearance = clearance; if (clearance >= 0f) bestMovement = movement; }
                    }
                    if (bestClearance >= 0f) break;
                }
                bool improved = bestClearance > initial + .001f * frameScale &&
                    AvatarArmIk.Apply(arm.Upper, arm.Lower, arm.Hand, best, bestBend, MaximumCorrectionDegrees);
                for (int i = arm.First; i < arm.First + 2; i++)
                {
                    Owned item = owned[i];
                    item.Target = improved ? Quaternion.RotateTowards(Quaternion.identity,
                        item.Bone.localRotation * Quaternion.Inverse(item.Source), MaximumCorrectionDegrees) : Quaternion.identity;
                }
                // Candidate evaluation never leaks an unsmoothed partial pose.
                for (int i = arm.First; i < arm.First + 3; i++) owned[i].Bone.localRotation = owned[i].Source;
            }
            else if (now - arm.LastContactAt >= ContactReleaseGraceSeconds)
                for (int i = arm.First; i < arm.First + 2; i++) owned[i].Target = Quaternion.identity;

            float response = 1f - Mathf.Exp(-delta / CorrectionResponseSeconds);
            bool wrote = false;
            for (int i = arm.First; i < arm.First + 2; i++)
            {
                Owned item = owned[i];
                Quaternion smooth = Quaternion.Slerp(item.Correction, item.Target, response);
                item.Correction = Quaternion.RotateTowards(item.Correction, smooth, MaximumCorrectionSpeedDegrees * delta);
                if (Quaternion.Angle(item.Correction, Quaternion.identity) < .001f) item.Correction = Quaternion.identity;
                item.Bone.localRotation = item.Correction * item.Source;
                wrote |= Quaternion.Angle(item.Correction, Quaternion.identity) > .001f;
            }
            if (wrote)
            {
                arm.Hand.rotation = wristRotation;
                for (int i = arm.First; i < arm.First + 3; i++) { owned[i].Written = owned[i].Bone.localRotation; owned[i].HasWrite = true; }
                CorrectedArms++;
            }
            return Clearance(arm, arm.Lower.position, arm.Hand.position, palmOffset);
        }

        private void ResetCorrections()
        {
            previousFrameAt = float.NaN;
            foreach (Owned item in owned) item.Correction = item.Target = Quaternion.identity;
            if (left != null) left.LastContactAt = float.NegativeInfinity;
            if (right != null) right.LastContactAt = float.NegativeInfinity;
        }
        private float Clearance(Arm arm, Vector3 elbow, Vector3 wrist, Vector3 palmOffset)
        {
            float radius = arm.Radius * frameScale, palm = arm.PalmRadius * frameScale;
            float minimum = float.PositiveInfinity;
            for (int i = 0; i <= 4; i++) minimum = Mathf.Min(minimum, SampleClearance(Vector3.Lerp(elbow, wrist, i * .25f), radius));
            for (int i = 0; i <= 2; i++) minimum = Mathf.Min(minimum, SampleClearance(wrist + palmOffset * (i * .5f), palm));
            for (int i = 0; i < arm.TipOffsets.Length; i++) minimum = Mathf.Min(minimum, SampleClearance(wrist + arm.TipOffsets[i], radius * .25f));
            return minimum;
        }
        public float PointClearance(Vector3 point, float radius = 0f)
        {
            if (!Bound || !Finite(point) || !Finite(radius)) return float.NaN;
            PrepareFrame(); return SampleClearance(point, radius);
        }
        private void PrepareFrame()
        {
            frameScale = RootScale;
            frameBody = new Capsule(hips.position, torsoTop.position, bodyRadius * frameScale);
            Vector3 center = HeadCenter;
            frameHead = new Capsule(center, center, headRadius * frameScale);
            frameMargin = Vector3.Distance(frameBody.A, frameBody.B) * MarginFraction;
        }
        private float SampleClearance(Vector3 point, float radius) =>
            Mathf.Min(Vector3.Distance(point, Closest(point, frameBody.A, frameBody.B)) - frameBody.Radius,
                Vector3.Distance(point, frameHead.A) - frameHead.Radius) - Mathf.Max(0f, radius) - frameMargin;
        public float ForearmRadius(bool isLeft) => Bound ? (isLeft ? left.Radius : right.Radius) * RootScale : 0f;
        public float PalmRadius(bool isLeft) => Bound ? (isLeft ? left.PalmRadius : right.PalmRadius) * RootScale : 0f;
        public float ArmClearance(bool isLeft)
        {
            if (!Bound) return float.NaN;
            PrepareFrame(); Arm arm = isLeft ? left : right;
            for (int i = 0; i < arm.Tips.Length; i++) arm.TipOffsets[i] = arm.Tips[i].position - arm.Hand.position;
            return Clearance(arm, arm.Lower.position, arm.Hand.position, arm.Middle.position - arm.Hand.position);
        }
        public void Reset()
        {
            RestoreBeforeAnimation(); ResetCorrections(); CorrectedArms = 0; Unresolved = false; LastMinimumClearance = float.PositiveInfinity;
        }
        private static Vector3 Closest(Vector3 point, Vector3 a, Vector3 b)
        { Vector3 axis = b - a; return axis.sqrMagnitude < .00000001f ? a : a + axis * Mathf.Clamp01(Vector3.Dot(point - a, axis) / axis.sqrMagnitude); }
        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
        private static bool Finite(Vector3 value) => Finite(value.x) && Finite(value.y) && Finite(value.z);
    }
}
