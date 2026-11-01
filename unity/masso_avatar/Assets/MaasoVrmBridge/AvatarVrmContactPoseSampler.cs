using System;
using UniVRM10;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Synchronizes only the loaded body's normalized pose for a
    /// bounded skin-contact probe. Never advances expression, mouth, gaze,
    /// constraints, springs or a frame, and never creates a control rig.</summary>
    public static class AvatarVrmContactPoseSampler
    {
        public static Action<Transform,Animator> Capture(Vrm10Runtime runtime,Transform expectedActor)
        {
            // The renderer supplies its already loaded runtime at model bind.
            // The contact probe never invokes Vrm10Instance's lazy Runtime getter.
            var controls=runtime?.ControlRig;
            var initialPose=runtime?.InitPose;
            if(controls==null || initialPose==null || expectedActor==null)return null;
            return (actor,animator)=>
            {
            if(expectedActor==null || actor!=expectedActor || animator==null ||
                controls.ControlRigAnimator!=animator)return;
            if(controls.Bones.TryGetValue(HumanBodyBones.Hips,out var hips) &&
                hips.ControlBone!=null && hips.ControlTarget!=null)
                hips.ControlTarget.position=hips.ControlBone.position;
            foreach(var pair in controls.Bones)
            {
                if(pair.Key is HumanBodyBones.Head or HumanBodyBones.Neck or HumanBodyBones.Jaw or
                    HumanBodyBones.LeftEye or HumanBodyBones.RightEye)continue;
                var bone=pair.Value;
                if(bone.ControlTarget==null || bone.ControlBone==null ||
                    !initialPose.TryGetValue(bone.ControlTarget,out var initial))continue;
                // Mapping from the pinned UniVRM SDK's public bone/InitPose:
                // Runtime/Components/Vrm10Runtime/ControlRig/Vrm10ControlBone.cs
                // ProcessRecursively (com.vrmc.vrm@48d64123d085). Only raw body
                // transforms saved by the caller's probe are touched.
                bone.ControlTarget.localRotation=initial.LocalRotation *
                    (Quaternion.Inverse(initial.Rotation)*bone.ControlBone.localRotation*initial.Rotation);
            }
            };
        }
    }
}
