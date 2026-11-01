using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Moves only the published sliding-door root; never creates a leaf.</summary>
    public sealed class PersonalSpacePocketDoor : MonoBehaviour
    {
        public Transform SlidingRoot;
        public Vector3 ClosedLocalPosition,OpenLocalPosition;
        public float Duration=.4f;
        private float progress;
        private bool requested;
        public bool Ready => SlidingRoot!=null && (SlidingRoot==transform || SlidingRoot.IsChildOf(transform)) &&
            (OpenLocalPosition-ClosedLocalPosition).sqrMagnitude>.01f;
        public bool IsOpen => Ready && progress>=.999f && Vector3.Distance(SlidingRoot.localPosition,OpenLocalPosition)<.002f;
        private void Start() => PresentOpenByDefault();
        public void PresentOpenByDefault()
        {
            if (!Ready) return;
            // The authored leaf is closed for source validation. The ordinary
            // bedroom view leaves it inside its pocket, clear of the doorway.
            progress = 1f;
            requested = true;
            SlidingRoot.localPosition = OpenLocalPosition;
        }
        public bool RequestOpen() {if(!Ready || !gameObject.activeInHierarchy)return false;requested=true;return true;}
        public void Advance(float deltaTime)
        {
            if(!requested || !Ready)return;
            progress=Mathf.MoveTowards(progress,1,Mathf.Max(0,deltaTime)/Mathf.Max(.05f,Duration));
            SlidingRoot.localPosition=Vector3.Lerp(ClosedLocalPosition,OpenLocalPosition,Mathf.SmoothStep(0,1,progress));
        }
        private void LateUpdate()=>Advance(Time.unscaledDeltaTime);
    }
}
