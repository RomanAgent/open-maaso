using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using UnityEngine;

namespace Maaso.Avatar
{
    [Serializable]
    public sealed class AvatarPhoneCommand
    {
        public string requestId, interactionId, phase;
        public long sequence, expiresAtMs;
    }

    [Serializable]
    public sealed class AvatarPhoneResult
    {
        public string method = "setPhoneInteraction";
        public string requestId, interactionId, phase, code;
        public bool ok;
    }

    /// <summary>Late upper-body overlay. Never changes root, legs, Animator state,
    /// face morphs or camera. The animated base pose is sampled afresh each frame.</summary>
    public sealed class AvatarPhoneInteractionController
    {
        private readonly Action<AvatarPhoneResult> report;
        private readonly HashSet<string> retired = new();
        private readonly Dictionary<Transform, (Quaternion before, Quaternion applied)> poses = new();
        private Transform root, head, hips, chest;
        private Animator animator;
        private AvatarPhoneProp prop;
        private AvatarPhoneCommand pending;
        private string interactionId, phase = "none";
        private long highWater;
        private float startedAt, touchedAt, startRaise, raise, startTyping, typing;
        private Quaternion leftHandBasis, rightHandBasis;
        private readonly Dictionary<Transform, Quaternion> fingerRest = new();
        private float leftPalmLength, rightPalmLength;
        private Vector3 replyReleasePosition;
        private Quaternion replyReleaseRotation;
        private float scale = 1f, phoneScale = 1f;
        public bool OwnsHands => interactionId != null;
        public GameObject Phone => prop?.Root;
        public string Phase => phase;
        public string InteractionId => interactionId;

        public AvatarPhoneInteractionController(Action<AvatarPhoneResult> report) => this.report = report;

        public void Execute(AvatarPhoneCommand command, Transform avatar, float now, long utcNowMs)
        {
            if (!Valid(command, utcNowMs)) { Reply(command, false, "invalid_or_expired_request"); return; }
            if (command.sequence <= highWater || retired.Contains(command.interactionId))
            { Reply(command, false, "stale_interaction"); return; }
            // A stale cancel/reply must not consume sequence authority belonging
            // to a different conversation, even when it arrives much later.
            if (command.phase != "reading" && interactionId != command.interactionId)
            { Reply(command, false, "stale_interaction"); return; }
            if (root != avatar && !Bind(avatar)) { Reply(command, false, "humanoid_hands_unavailable"); return; }
            if (root == null || animator == null) { Reply(command, false, "humanoid_hands_unavailable"); return; }
            highWater = command.sequence;
            if (pending != null) Reply(pending, false, "superseded");
            if (interactionId != null && interactionId != command.interactionId) retired.Add(interactionId);
            interactionId = command.interactionId;
            pending = command;
            if (command.phase == "none" && phase != "none")
            {
                replyReleasePosition = prop.Root.transform.position;
                replyReleaseRotation = prop.Root.transform.rotation;
            }
            phase = command.phase;
            startedAt = touchedAt = now;
            startRaise = raise;
            startTyping = typing;
            prop.Root.SetActive(true);
        }

        private bool Bind(Transform avatar)
        {
            Reset("model_replaced");
            if (avatar == null) return false;
            var candidate = avatar.GetComponentInChildren<Animator>();
            if (candidate == null || !candidate.isHuman || candidate.avatar == null) return false;
            foreach (HumanBodyBones bone in new[] { HumanBodyBones.Head, HumanBodyBones.Hips,
                HumanBodyBones.LeftUpperArm, HumanBodyBones.LeftLowerArm, HumanBodyBones.LeftHand,
                HumanBodyBones.RightUpperArm, HumanBodyBones.RightLowerArm, HumanBodyBones.RightHand })
                if (candidate.GetBoneTransform(bone) == null) return false;
            root = avatar; animator = candidate;
            head = Bone(HumanBodyBones.Head); hips = Bone(HumanBodyBones.Hips);
            chest = Bone(HumanBodyBones.Chest) ?? Bone(HumanBodyBones.Spine);
            scale = Mathf.Clamp(Vector3.Distance(head.position, hips.position) / .65f, .5f, 2f);
            leftHandBasis = HandBasis(true); rightHandBasis = HandBasis(false);
            leftPalmLength = PalmLength(true); rightPalmLength = PalmLength(false);
            // Fit the holding palm, not the torso or a minimum-size tablet.
            // Knuckle span excludes the flesh at the palm edges; allow 12% for
            // that while keeping height within 1.6 wrist-to-middle-knuckle lengths.
            float palmWidth = PalmWidth(true);
            phoneScale = Mathf.Min(palmWidth * 1.12f / AvatarPhoneProp.WidthMeters,
                leftPalmLength * 1.6f / AvatarPhoneProp.HeightMeters);
            CaptureFingerRest();
            prop = new AvatarPhoneProp(root);
            // World dimensions follow the humanoid proportions, independently
            // of the importer's root scale.
            Vector3 rootScale = root.lossyScale;
            prop.Root.transform.localScale = new Vector3(phoneScale / Mathf.Abs(rootScale.x),
                phoneScale / Mathf.Abs(rootScale.y), phoneScale / Mathf.Abs(rootScale.z));
            return true;
        }

        public void RestorePose()
        {
            foreach (var pair in poses)
                if (pair.Key != null && Quaternion.Angle(pair.Key.localRotation, pair.Value.applied) < .05f)
                    pair.Key.localRotation = pair.Value.before;
            poses.Clear();
        }

        public void Advance(float now, long utcNowMs)
        {
            RestorePose();
            if (!OwnsHands || root == null) return;
            if (pending != null && utcNowMs > pending.expiresAtMs) { Reset("deadline_expired"); return; }
            // A disconnected or destroyed owner cannot leave a prop held forever.
            if (now - touchedAt > 45f) { Reset("interaction_expired"); return; }
            float duration = phase == "none" ? .85f : phase == "reading" ? 1.05f : .38f;
            float progress = Mathf.Clamp01((now - startedAt) / duration);
            float eased = Mathf.SmoothStep(0f, 1f, progress);
            // Reach the pocket first. The final .25s releases a stationary
            // pocket pose, instead of rotating the phone while blending out IK.
            float liftEase = phase == "none"
                ? Mathf.SmoothStep(0f, 1f, Mathf.Clamp01((now - startedAt) / .60f)) : eased;
            raise = Mathf.Lerp(startRaise, phase == "none" ? 0f : 1f, liftEase);
            // The replying hand releases before the holding hand reaches the
            // opposite hip. Otherwise its IK target pulls it across the torso.
            float typingEase = phase == "none"
                ? Mathf.SmoothStep(0f, 1f, Mathf.Clamp01((now - startedAt) / .30f)) : eased;
            typing = Mathf.Lerp(startTyping, phase == "replying" ? 1f : 0f, typingEase);
            Pose(now);
            if (progress < 1f) return;
            AvatarPhoneCommand completed = pending;
            pending = null;
            if (phase == "none")
            {
                retired.Add(interactionId); interactionId = null;
                prop.Root.SetActive(false); RestorePose();
            }
            if (completed != null) Reply(completed, true, "completed");
        }

        private void Pose(float now)
        {
            Vector3 right = root.right, up = root.up, forward = root.forward;
            // The hip-side pickup remains outside garments, including dresses
            // with no pocket. The outward arc keeps the phone clear of the body.
            Vector3 pocket = hips.position - right * (.23f * scale) + forward * (.11f * scale) - up * (.10f * scale);
            Vector3 reading = (chest != null ? chest.position : head.position - up * .3f * scale)
                - right * (Mathf.Lerp(.060f, 0f, typing) * scale)
                + forward * (.31f * scale) + up * (.19f * scale);
            Vector3 phoneAt = Vector3.Lerp(pocket, reading, raise)
                - right * (Mathf.Sin(raise * Mathf.PI) * .06f * scale);
            Quaternion upright = Quaternion.LookRotation((-forward + up * .4f).normalized, up);
            // Fingers point down when reaching the hip. The phone turns with
            // the forearm on the way up instead of requiring a folded wrist.
            Quaternion pocketRotation = Quaternion.LookRotation(forward, -up);
            Quaternion intended = Quaternion.Slerp(pocketRotation, upright, raise);
            Quaternion phoneRotation = intended;
            Transform upper = Bone(HumanBodyBones.LeftUpperArm);
            Transform lower = Bone(HumanBodyBones.LeftLowerArm);
            Transform holdingHand = Bone(HumanBodyBones.LeftHand);
            // Couple the prop to the arm before applying the overlay. Using
            // measured palm length keeps the same contact on different avatars.
            for (int pass = 0; pass < 4; pass++)
            {
                Vector3 wrist = GripWrist(true, phoneAt, phoneRotation);
                Vector3 elbow = ChainElbow(upper, lower, holdingHand, wrist, ArmElbowHint(true, wrist));
                Vector3 fingers = Vector3.RotateTowards((wrist - elbow).normalized,
                    intended * Vector3.up, 35f * Mathf.Deg2Rad, 0f);
                phoneRotation = Quaternion.LookRotation(
                    Vector3.ProjectOnPlane(intended * Vector3.forward, fingers).normalized, fingers);
            }
            Transform phone = prop.Root.transform;
            phone.SetPositionAndRotation(phoneAt, phoneRotation);
            float handWeight = phase == "reading" && startRaise < .01f
                ? Mathf.SmoothStep(0f, 1f, Mathf.Clamp01((now - startedAt) / .18f))
                : phase == "none" ? 1f - Mathf.SmoothStep(0f, 1f, Mathf.Clamp01((now - startedAt - .60f) / .25f)) : 1f;
            prop.Root.SetActive(phase == "none" ? now - startedAt < .60f : handWeight > .97f || raise > .08f);
            GripHand(true, phoneAt, phoneRotation, handWeight);
            CurlFingers(true, handWeight, now);
            if (typing > .001f)
            {
                GripHand(false, phase == "none" ? replyReleasePosition : phoneAt,
                    phase == "none" ? replyReleaseRotation : phoneRotation, typing);
                CurlFingers(false, typing, now);
            }
            // Only head/neck rotation: TTS expressions and lip-sync retain all
            // mouth ownership. A concurrent gaze resumes automatically afterward.
            Transform neck = Bone(HumanBodyBones.Neck);
            if (neck != null) WriteWorld(neck, Quaternion.AngleAxis(9f * raise, right) * neck.rotation);
            WriteWorld(head, Quaternion.AngleAxis(18f * raise, right) * head.rotation);
        }

        private Vector3 GripWrist(bool left, Vector3 at, Quaternion rotation)
        {
            // Phone-local +X is the avatar's LEFT while its screen faces them.
            Vector3 contact = at + rotation * new Vector3(
                (left ? .052f : -.058f) * phoneScale,
                (left ? -.010f : -.040f) * phoneScale, -.009f * phoneScale);
            return contact - rotation * Vector3.up * (left ? leftPalmLength : rightPalmLength);
        }

        private void GripHand(bool left, Vector3 at, Quaternion rotation, float weight)
        {
            if (weight <= 0f) return;
            Transform upper = Bone(left ? HumanBodyBones.LeftUpperArm : HumanBodyBones.RightUpperArm);
            Transform lower = Bone(left ? HumanBodyBones.LeftLowerArm : HumanBodyBones.RightLowerArm);
            Transform hand = Bone(left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand);
            Quaternion basis = left ? leftHandBasis : rightHandBasis;
            Quaternion originalUpper = upper.localRotation, originalLower = lower.localRotation, originalHand = hand.localRotation;
            Vector3 target = GripWrist(left, at, rotation);
            // Solve one coherent grip before blending. Applying pronation on an
            // already half-blended IK chain created a second rotation weight and
            // a +/-180-degree roll branch during release.
            SolveChain(upper, lower, hand, target, ArmElbowHint(left, target), 1f);
            Vector3 forearm = (hand.position - lower.position).normalized;
            Vector3 fingers = Vector3.RotateTowards(forearm, rotation * Vector3.up, 35f * Mathf.Deg2Rad, 0f);
            // The calibrated normal is the BACK of the hand. Palms face the
            // phone's side/back, with thumbs free to reach the display.
            Vector3 back = rotation * new Vector3(left ? .94f : -.94f, 0f, -.34f);
            Quaternion desired = Quaternion.LookRotation(Vector3.ProjectOnPlane(back, fingers), fingers)
                * Quaternion.Inverse(basis);
            // Forearm pronation supplies the grip roll. Do not put the whole
            // rotation into the wrist joint while leaving the forearm behind.
            Vector3 oldBack = Vector3.ProjectOnPlane(hand.rotation * basis * Vector3.forward, forearm);
            Vector3 newBack = Vector3.ProjectOnPlane(desired * basis * Vector3.forward, forearm);
            float roll = Vector3.SignedAngle(oldBack, newBack, forearm);
            WriteWorld(lower, Quaternion.AngleAxis(roll, forearm) * lower.rotation);
            WriteWorld(hand, desired);
            Quaternion solvedUpper = upper.localRotation, solvedLower = lower.localRotation, solvedHand = hand.localRotation;
            WriteLocal(upper, Quaternion.Slerp(originalUpper, solvedUpper, weight));
            WriteLocal(lower, Quaternion.Slerp(originalLower, solvedLower, weight));
            WriteLocal(hand, Quaternion.Slerp(originalHand, solvedHand, weight));
        }

        private Vector3 ArmElbowHint(bool left, Vector3 target)
        {
            Transform upper = Bone(left ? HumanBodyBones.LeftUpperArm : HumanBodyBones.RightUpperArm);
            Vector3 direction = (target - upper.position).normalized;
            Vector3 outside = Vector3.ProjectOnPlane(root.right * (left ? -1f : 1f), direction);
            if (outside.sqrMagnitude < .001f)
                outside = Vector3.ProjectOnPlane(root.forward, direction);
            outside.Normalize();
            // Keep a positive outward component. The downward preference is
            // orthogonal to it, so the bend plane cannot collapse or flip when
            // the descending wrist passes a fixed hip-side pole point.
            Vector3 down = Vector3.ProjectOnPlane(Vector3.ProjectOnPlane(-root.up, direction), outside);
            Vector3 bend = (outside * .35f + down).normalized;
            return upper.position + bend * scale;
        }

        private Vector3 ChainElbow(Transform upper, Transform lower, Transform hand, Vector3 target, Vector3 hint)
        {
            Vector3 origin = upper.position;
            float a = Vector3.Distance(origin, lower.position), b = Vector3.Distance(lower.position, hand.position);
            Vector3 direction = (target - origin).normalized;
            float distance = Mathf.Clamp(Vector3.Distance(origin, target), Mathf.Abs(a - b) + .001f, a + b - .001f);
            Vector3 bend = Vector3.ProjectOnPlane(hint - origin, direction).normalized;
            if (bend.sqrMagnitude < .1f) bend = Vector3.Cross(direction, root.forward).normalized;
            float along = (a * a - b * b + distance * distance) / (2f * distance);
            return origin + direction * along + bend * Mathf.Sqrt(Mathf.Max(0f, a * a - along * along));
        }

        private void SolveChain(Transform upper, Transform lower, Transform hand, Vector3 target, Vector3 hint, float weight)
        {
            if (weight <= 0f) return;
            Quaternion originalUpper = upper.localRotation, originalLower = lower.localRotation;
            Vector3 origin = upper.position;
            Vector3 elbow = ChainElbow(upper, lower, hand, target, hint);
            WriteWorld(upper, Quaternion.FromToRotation(lower.position - origin, elbow - origin) * upper.rotation);
            WriteWorld(lower, Quaternion.FromToRotation(hand.position - lower.position, target - lower.position) * lower.rotation);
            Quaternion solvedUpper = upper.localRotation, solvedLower = lower.localRotation;
            WriteLocal(upper, Quaternion.Slerp(originalUpper, solvedUpper, weight));
            WriteLocal(lower, Quaternion.Slerp(originalLower, solvedLower, weight));
        }

        private float PalmLength(bool left)
        {
            Transform hand = Bone(left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand);
            Transform middle = Bone(left ? HumanBodyBones.LeftMiddleProximal : HumanBodyBones.RightMiddleProximal);
            return middle != null ? Vector3.Distance(hand.position, middle.position) : .08f * scale;
        }

        private float PalmWidth(bool left)
        {
            Transform index = Bone(left ? HumanBodyBones.LeftIndexProximal : HumanBodyBones.RightIndexProximal);
            Transform little = Bone(left ? HumanBodyBones.LeftLittleProximal : HumanBodyBones.RightLittleProximal);
            return index != null && little != null
                ? Vector3.Distance(index.position, little.position) : .065f * scale;
        }

        private void CaptureFingerRest()
        {
            // Skin bind matrices give a stable reference even if an animation
            // has already curled the fingers when the first message arrives.
            fingerRest.Clear();
            var bindWorld = new Dictionary<Transform, Matrix4x4>();
            foreach (SkinnedMeshRenderer skin in root.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                if (skin.sharedMesh == null) continue;
                Matrix4x4[] binds = skin.sharedMesh.bindposes;
                Transform[] bones = skin.bones;
                for (int i = 0; i < Mathf.Min(binds.Length, bones.Length); i++)
                    if (bones[i] != null && !bindWorld.ContainsKey(bones[i]))
                        bindWorld.Add(bones[i], skin.transform.localToWorldMatrix * binds[i].inverse);
            }
            foreach (var pair in bindWorld)
                if (pair.Key.parent != null && bindWorld.TryGetValue(pair.Key.parent, out Matrix4x4 parent))
                    fingerRest[pair.Key] = (parent.inverse * pair.Value).rotation;
        }

        private Quaternion HandBasis(bool left)
        {
            Transform hand = Bone(left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand);
            Transform middle = Bone(left ? HumanBodyBones.LeftMiddleProximal : HumanBodyBones.RightMiddleProximal);
            Transform index = Bone(left ? HumanBodyBones.LeftIndexProximal : HumanBodyBones.RightIndexProximal);
            Transform little = Bone(left ? HumanBodyBones.LeftLittleProximal : HumanBodyBones.RightLittleProximal);
            if (middle == null || index == null || little == null) return Quaternion.identity;
            Vector3 fingers = hand.InverseTransformDirection(middle.position - hand.position).normalized;
            Vector3 across = hand.InverseTransformDirection(index.position - little.position).normalized;
            Vector3 normal = Vector3.Cross(across, fingers) * (left ? -1 : 1);
            return Quaternion.LookRotation(normal, fingers);
        }

        private void CurlFingers(bool left, float weight, float now)
        {
            HumanBodyBones first = left ? HumanBodyBones.LeftIndexProximal : HumanBodyBones.RightIndexProximal;
            // Unity's four non-thumb fingers are contiguous proximal/intermediate/distal triplets.
            for (int finger = 0; finger < 4; finger++)
                for (int joint = 0; joint < 3; joint++)
                {
                    Transform bone = Bone((HumanBodyBones)((int)first + finger * 3 + joint));
                    if (bone == null) continue;
                    Quaternion rest = fingerRest.TryGetValue(bone, out Quaternion reference) ? reference : bone.localRotation;
                    Quaternion basis = left ? leftHandBasis : rightHandBasis;
                    Transform hand = Bone(left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand);
                    Vector3 across = hand.rotation * basis * Vector3.right;
                    float angle = joint == 0 ? 28f : joint == 1 ? 55f : 22f;
                    Quaternion desired = Quaternion.AngleAxis(-angle, across) * bone.parent.rotation * rest;
                    WriteWorld(bone, Quaternion.Slerp(bone.rotation, desired, weight));
                }
            Transform thumb = Bone(left ? HumanBodyBones.LeftThumbProximal : HumanBodyBones.RightThumbProximal);
            Transform middle = Bone(left ? HumanBodyBones.LeftThumbIntermediate : HumanBodyBones.RightThumbIntermediate);
            Transform tip = Bone(left ? HumanBodyBones.LeftThumbDistal : HumanBodyBones.RightThumbDistal);
            if (thumb == null || middle == null || tip == null) return;
            Transform phone = prop.Root.transform;
            bool releasingReply = !left && phase == "none";
            Vector3 phoneAt = releasingReply ? replyReleasePosition : phone.position;
            Quaternion phoneRotation = releasingReply ? replyReleaseRotation : phone.rotation;
            Vector3 phoneRight = phoneRotation * Vector3.right, phoneUp = phoneRotation * Vector3.up;
            Vector3 phoneForward = phoneRotation * Vector3.forward;
            float tap = left ? 0f : (Mathf.Sin(now * 13f) * .5f + .5f);
            Vector3 towardScreen = phoneRight * (left ? -1f : 1f);
            Vector3 contact = phoneAt - phoneUp * (.035f * phoneScale)
                + phoneRight * ((left ? .024f : -.009f) * phoneScale)
                + phoneForward * ((.009f + tap * .008f) * phoneScale);
            SolveChain(thumb, middle, tip, contact - towardScreen * (.014f * phoneScale),
                phoneAt - phoneUp * (.1f * phoneScale), weight);
            Vector3 currentDirection = tip.childCount > 0 ? tip.GetChild(0).position - tip.position : tip.position - middle.position;
            WriteWorld(tip, Quaternion.Slerp(tip.rotation,
                Quaternion.FromToRotation(currentDirection, towardScreen) * tip.rotation, weight));
        }

        private Transform Bone(HumanBodyBones bone) => animator.GetBoneTransform(bone);
        private void WriteWorld(Transform bone, Quaternion rotation) =>
            WriteLocal(bone, bone.parent == null ? rotation : Quaternion.Inverse(bone.parent.rotation) * rotation);
        private void WriteLocal(Transform bone, Quaternion rotation)
        {
            if (bone == null) return;
            if (!poses.TryGetValue(bone, out var previous)) previous = (bone.localRotation, rotation);
            bone.localRotation = rotation; poses[bone] = (previous.before, rotation);
        }

        public void Reset(string reason)
        {
            if (pending != null) Reply(pending, false, reason);
            pending = null;
            if (interactionId != null) retired.Add(interactionId);
            interactionId = null; phase = "none"; raise = typing = 0f;
            RestorePose();
            prop?.Dispose(); prop = null; root = null; animator = null; fingerRest.Clear();
        }

        private static bool Valid(AvatarPhoneCommand command, long now) => command != null &&
            Identifier(command.requestId) && Identifier(command.interactionId) && command.sequence > 0 &&
            command.expiresAtMs >= now && command.expiresAtMs - now <= 10000 &&
            (command.phase == "reading" || command.phase == "replying" || command.phase == "none");
        private static bool Identifier(string id) => id != null && Regex.IsMatch(id, "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$");
        private void Reply(AvatarPhoneCommand command, bool ok, string code) => report(new AvatarPhoneResult
        {
            requestId = command?.requestId, interactionId = command?.interactionId,
            phase = command?.phase, ok = ok, code = code,
        });
    }
}
