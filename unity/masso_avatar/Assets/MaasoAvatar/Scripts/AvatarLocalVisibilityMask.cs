using System;
using System.Collections.Generic;
using UnityEngine;

namespace Maaso.Avatar
{
    [Serializable]
    public sealed class LocalAvatarVisibilityCommand { public bool visible; }

    /// <summary>Account ownership uses Renderer.enabled; device-presence
    /// animation independently owns forceRenderingOff. The two gates are ANDed,
    /// so preparation never captures an ownership mask as its original flags.</summary>
    public sealed class AvatarLocalVisibilityMask
    {
        private readonly Dictionary<Renderer, bool> held = new();
        public bool Visible { get; private set; }

        public void SetVisible(bool visible) => Visible = visible;

        public void Apply(Transform localRoot, bool presenceHidden)
        {
            if (localRoot == null) return;
            if (Visible)
            {
                foreach (var pair in held)
                    if (pair.Key != null && !pair.Key.enabled)
                        pair.Key.enabled = pair.Value;
                held.Clear();
                return;
            }
            foreach (Renderer renderer in localRoot.GetComponentsInChildren<Renderer>(true))
            {
                if (!held.ContainsKey(renderer)) held[renderer] = renderer.enabled;
                renderer.enabled = false;
            }
        }
    }
}
