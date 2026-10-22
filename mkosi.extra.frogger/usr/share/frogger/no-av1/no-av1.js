// Report AV1 as unsupported to the page; every other type is answered as before.
(() => {
  const isAV1 = (type) => /av01/i.test(String(type));

  const mse = globalThis.MediaSource;
  if (mse && mse.isTypeSupported) {
    const orig = mse.isTypeSupported.bind(mse);
    mse.isTypeSupported = (type) => !isAV1(type) && orig(type);
  }

  const proto = globalThis.HTMLMediaElement && HTMLMediaElement.prototype;
  if (proto && proto.canPlayType) {
    const orig = proto.canPlayType;
    proto.canPlayType = function (type) { return isAV1(type) ? '' : orig.call(this, type); };
  }

  const mc = globalThis.navigator && navigator.mediaCapabilities;
  if (mc && mc.decodingInfo) {
    const orig = mc.decodingInfo.bind(mc);
    mc.decodingInfo = (config) => (config && config.video && isAV1(config.video.contentType))
      ? Promise.resolve({ supported: false, smooth: false, powerEfficient: false })
      : orig(config);
  }
})();
