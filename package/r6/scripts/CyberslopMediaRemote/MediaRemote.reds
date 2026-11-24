// Cyberslop Media Remote 1.0.3 (2026-11-23; 1.0.2 (CET only) and 1.0.1 2026-11-22)
// 1.0.3: a radio set back to 100 % while it is off gets its 100 % values at once (turned on later it played at
//   the old, lower level, because the play-station wrap only applies levels below 100).
// 1.0.1 (review fixes): one RWLock around the device registry and the saved levels (device tasks
// and CET touch them from different threads), quest unmute re-applies the saved TV level, UI key from
// EntityID.ToDebugStringDecimal (no Uint32 -> Int32 cast).
// Remote control for the world radios and TVs around V: power, station / channel, volume, mute.
// The CET window (mods\CyberslopMediaRemote) is only the face; everything that touches the game is here.
//
// Lightweight by design:
// - no per-frame work: devices register themselves when they resolve their gameplay state (stream-in),
//   the list is only filtered by distance when the CET window or a remote key asks for it;
// - no replaced assets, no extra emitters: power and tuning use the game's own quest actions
//   (QuestForceON/OFF, QuestSetChannel; no NPC distraction, unlike the hand interaction),
//   volume uses the game's own Wwise game parameters on the device's emitter;
// - saved per save game: only the devices whose volume differs from 100 (max 256 entries).
//
// Volume, from the 2.5 sound banks (radio.bnk):
// - TV: game parameter tv_receiver_volume drives global_tv_channel_00..04, linear gain 0..1 (default 1).
//   Vanilla's own mute_tv_emitter / unmute_tv_emitter events just set it to 0 / 1 with a 500 ms fade.
//   Knob position p -> gain (p/100)^2, so 50 % = -12 dB, 70 % = -6 dB.
// - Radio: the world radio sounds (radio_default / _int / _ext) carry no volume parameter of their own.
//   Per-emitter values of focus_mode (0..-5 dB), vo_dialog_active (0..-2 dB, -4.5 on _int/_ext) and
//   game_occlusion (0..-12 dB, also muffles) give up to about -19 dB. 0 % = the station_none switch.
//   A per-object value beats the engine's global one; game_occlusion may be rewritten by the engine's
//   occlusion pass (then the floor is about -7 dB).
//
// Reused ideas: station_none switch (Radio Silence 9262 / World Radios Silenced 12856 / Sound of Silence 17081),
// mute_tv_emitter (TV Mute Control 14149). Nothing of Radio/TV Volume Control's emitter stacking is used.

module CyberslopMediaRemote

@if(ModuleExists("NightCityFinance.Amenities"))
import NightCityFinance.Amenities.*

// ---------------------------------------------------------------------------------------------------
// What the CET window reads for one device.

public class MediaRemoteEntry extends IScriptable {
  public let key: String;        // stable id for the UI (entity hash)
  public let kind: Int32;        // 1 radio, 2 TV
  public let name: String;
  public let isOn: Bool;
  public let usable: Bool;       // false: reason says why (no power, broken, locked, rent)
  public let reason: String;
  public let soundLocked: Bool;  // TV muted by its scene / quest: volume left alone
  public let station: String;
  public let stationIndex: Int32;// radio: dial position, TV: channel index, -1 none
  public let level: Int32;       // 0..100
  public let distance: Float;
  public let place: String;      // "ahead", "left", ... "upstairs"
  public let lookedAt: Bool;
  public let isPublic: Bool;     // V can't use it by hand (bar radio, quest TV)
}

// Re-applies a TV's volume after the vanilla turn-on fade is over.
public class MediaRemoteReapply extends DelayCallback {
  public let device: wref<Device>;

  public func Call() -> Void {
    let tv: ref<TV> = this.device as TV;
    if IsDefined(tv) && tv.IsAttached() {
      tv.CMR_Apply(MediaRemoteSystem.LevelFor(tv), false);
    }
  }
}

public class MediaRemoteSystem extends ScriptableSystem {
  private persistent let m_ids: array<EntityID>;
  private persistent let m_levels: array<Int32>;
  private let m_devices: array<wref<Device>>;
  private let m_view: array<wref<Device>>;
  private let m_viewDist: array<Float>;
  private let m_look: wref<Device>;
  // Guards m_devices, m_ids and m_levels. Never held while calling into another locked function.
  private let m_lock: RWLock;

  // How far a device you look at can be and still answer the remote.
  private let m_reach: Float = 40.0;

  public final static func Get(game: GameInstance) -> ref<MediaRemoteSystem> {
    return GameInstance.GetScriptableSystemsContainer(game).Get(n"CyberslopMediaRemote.MediaRemoteSystem") as MediaRemoteSystem;
  }

  public final static func LevelFor(device: ref<Device>) -> Int32 {
    if !IsDefined(device) { return 100; }
    let sys: ref<MediaRemoteSystem> = MediaRemoteSystem.Get(device.GetGame());
    return IsDefined(sys) ? sys.LevelOf(device.GetEntityID()) : 100;
  }

  public final static func ReapplyLater(device: ref<Device>, delay: Float) -> Void {
    let cb: ref<MediaRemoteReapply> = new MediaRemoteReapply();
    cb.device = device;
    GameInstance.GetDelaySystem(device.GetGame()).DelayCallback(cb, delay, false);
  }

  // --- registry -----------------------------------------------------------------------------------

  public final func Register(device: ref<Device>) -> Void {
    let d: ref<Device>;
    let known: Bool = false;
    let i: Int32;
    RWLock.Acquire(this.m_lock);
    i = ArraySize(this.m_devices) - 1;
    while i >= 0 {
      d = this.m_devices[i];
      if !IsDefined(d) || !d.IsAttached() {
        ArrayErase(this.m_devices, i);
      } else {
        if d == device { known = true; }
      }
      i -= 1;
    }
    if !known {
      ArrayPush(this.m_devices, device);
    }
    RWLock.Release(this.m_lock);
  }

  // --- saved volume -------------------------------------------------------------------------------

  private final func FindId(id: EntityID) -> Int32 {
    let i: Int32 = 0;
    while i < ArraySize(this.m_ids) {
      if this.m_ids[i] == id { return i; }
      i += 1;
    }
    return -1;
  }

  public final func LevelOf(id: EntityID) -> Int32 {
    let level: Int32 = 100;
    let i: Int32;
    RWLock.AcquireShared(this.m_lock);
    i = this.FindId(id);
    if i >= 0 && i < ArraySize(this.m_levels) {
      level = this.m_levels[i];
    }
    RWLock.ReleaseShared(this.m_lock);
    return level;
  }

  private final func StoreLevel(id: EntityID, level: Int32) -> Void {
    let i: Int32;
    RWLock.Acquire(this.m_lock);
    i = this.FindId(id);
    if level >= 100 {
      if i >= 0 {
        ArrayErase(this.m_ids, i);
        ArrayErase(this.m_levels, i);
      }
    } else {
      if i >= 0 {
        this.m_levels[i] = level;
      } else {
        if ArraySize(this.m_ids) >= 256 {
          ArrayErase(this.m_ids, 0);
          ArrayErase(this.m_levels, 0);
        }
        ArrayPush(this.m_ids, id);
        ArrayPush(this.m_levels, level);
      }
    }
    RWLock.Release(this.m_lock);
  }

  // --- list for the window / the remote keys ------------------------------------------------------

  // Devices within range, nearest first; the one V looks at (up to 40 m) goes on top.
  public final func Scan(range: Float) -> Int32 {
    let game: GameInstance = this.GetGameInstance();
    let player: ref<PlayerPuppet> = GetPlayer(game);
    let d: ref<Device>;
    let look: ref<Device>;
    let pos: Vector4;
    let dist: Float;
    let key: Float;
    let i: Int32;
    let j: Int32;
    ArrayClear(this.m_view);
    ArrayClear(this.m_viewDist);
    this.m_look = null;
    if !IsDefined(player) { return 0; }
    pos = player.GetWorldPosition();
    look = GameInstance.GetTargetingSystem(game).GetLookAtObject(player, false, false) as Device;
    RWLock.Acquire(this.m_lock);
    i = ArraySize(this.m_devices) - 1;
    while i >= 0 {
      d = this.m_devices[i];
      if !IsDefined(d) || !d.IsAttached() {
        ArrayErase(this.m_devices, i);
      } else {
        dist = Vector4.Distance(pos, d.GetWorldPosition());
        if dist <= range || (d == look && dist <= this.m_reach) {
          key = dist;
          if d == look {
            key = -1.0;
            this.m_look = d;
          }
          j = 0;
          while j < ArraySize(this.m_viewDist) && this.m_viewDist[j] <= key { j += 1; }
          ArrayInsert(this.m_view, j, d);
          ArrayInsert(this.m_viewDist, j, key);
        }
      }
      i -= 1;
    }
    RWLock.Release(this.m_lock);
    return ArraySize(this.m_view);
  }

  private final func At(i: Int32) -> ref<Device> {
    if i < 0 || i >= ArraySize(this.m_view) { return null; }
    let d: ref<Device> = this.m_view[i];
    return IsDefined(d) && d.IsAttached() ? d : null;
  }

  public final func Entry(i: Int32) -> ref<MediaRemoteEntry> {
    let d: ref<Device> = this.At(i);
    let e: ref<MediaRemoteEntry>;
    let radio: ref<Radio>;
    let tv: ref<TV>;
    let rps: ref<RadioControllerPS>;
    let tps: ref<TVControllerPS>;
    let ps: ref<ScriptableDeviceComponentPS>;
    let idx: Int32;
    if !IsDefined(d) { return null; }
    e = new MediaRemoteEntry();
    ps = d.GetDevicePS();
    e.key = EntityID.ToDebugStringDecimal(d.GetEntityID());
    e.level = this.LevelOf(d.GetEntityID());
    e.isOn = ps.IsON();
    e.isPublic = !ps.IsInteractive();
    e.lookedAt = d == this.m_look;
    this.FillPlace(d, e);
    this.FillUsable(ps, e);
    radio = d as Radio;
    if IsDefined(radio) {
      rps = radio.GetDevicePS();
      e.kind = 1;
      e.name = CMR_Text(rps.GetDeviceName(), "Radio");
      idx = rps.GetActiveStationIndex();
      if idx < 0 {
        e.station = "No station";
        e.stationIndex = -1;
      } else {
        e.station = CMR_StationText(IntEnum<ERadioStationList>(idx));
        e.stationIndex = RadioStationDataProvider.GetRadioStationUIIndex(idx);
      }
      return e;
    }
    tv = d as TV;
    if IsDefined(tv) {
      tps = tv.GetDevicePS();
      e.kind = 2;
      e.name = CMR_Text(tps.GetDeviceName(), "TV");
      e.soundLocked = tps.IsInterfaceMuted();
      idx = tps.GetActiveStationIndex();
      e.stationIndex = idx;
      e.station = CMR_Text(tps.GetChannelName(idx), "Channel " + IntToString(idx + 1));
    }
    return e;
  }

  private final func FillPlace(d: ref<Device>, e: ref<MediaRemoteEntry>) -> Void {
    let player: ref<PlayerPuppet> = GetPlayer(this.GetGameInstance());
    let to: Vector4 = d.GetWorldPosition() - player.GetWorldPosition();
    let fwd: Vector4 = player.GetWorldForward();
    let ahead: Float = to.X * fwd.X + to.Y * fwd.Y;
    let right: Float = to.X * fwd.Y - to.Y * fwd.X;
    e.distance = Vector4.Distance(player.GetWorldPosition(), d.GetWorldPosition());
    if AbsF(ahead) >= AbsF(right) {
      e.place = ahead >= 0.0 ? "ahead" : "behind";
    } else {
      e.place = right >= 0.0 ? "right" : "left";
    }
    if to.Z > 2.5 {
      e.place += ", upstairs";
    } else {
      if to.Z < -2.5 { e.place += ", downstairs"; }
    }
  }

  private final func FillUsable(ps: ref<ScriptableDeviceComponentPS>, e: ref<MediaRemoteEntry>) -> Void {
    let player: ref<PlayerPuppet> = GetPlayer(this.GetGameInstance());
    e.usable = false;
    if ps.IsDisabled() { e.reason = "disabled"; return; }
    if ps.IsUnpowered() { e.reason = "no power"; return; }
    if ps.IsBroken() { e.reason = "broken"; return; }
    if IsDefined(player) && !ps.IsUserAuthorized(player.GetEntityID()) { e.reason = "locked"; return; }
    if CMR_ServicesCut(this.GetGameInstance()) { e.reason = "power cut: rent unpaid"; return; }
    e.usable = true;
  }

  private final func Usable(d: ref<Device>) -> Bool {
    let e: ref<MediaRemoteEntry> = new MediaRemoteEntry();
    this.FillUsable(d.GetDevicePS(), e);
    return e.usable;
  }

  // --- controls -----------------------------------------------------------------------------------

  public final func Power(i: Int32, on: Bool) -> Bool {
    let d: ref<Device> = this.At(i);
    let ps: ref<ScriptableDeviceComponentPS>;
    if !IsDefined(d) || !this.Usable(d) { return false; }
    ps = d.GetDevicePS();
    if on {
      if ps.IsON() { return true; }
      ps.ExecutePSAction(ps.ActionQuestForceON());
    } else {
      if !ps.IsON() { return true; }
      ps.ExecutePSAction(ps.ActionQuestForceOFF());
    }
    return true;
  }

  public final func StationCount(i: Int32) -> Int32 {
    let d: ref<Device> = this.At(i);
    let tv: ref<TV>;
    if !IsDefined(d) { return 0; }
    if IsDefined(d as Radio) { return RadioStationDataProvider.GetStationsCount(); }
    tv = d as TV;
    return IsDefined(tv) ? tv.GetDevicePS().CMR_ChannelCount() : 0;
  }

  // "" = not offered (Samizdat: vanilla world radios step over it too).
  public final func StationName(i: Int32, j: Int32) -> String {
    let d: ref<Device> = this.At(i);
    let tv: ref<TV>;
    let station: ERadioStationList;
    if !IsDefined(d) { return ""; }
    if IsDefined(d as Radio) {
      station = RadioStationDataProvider.GetRadioStationByUIIndex(j);
      if Equals(station, ERadioStationList.MINIMAL_TECHNO) { return ""; }
      return CMR_StationText(station);
    }
    tv = d as TV;
    if IsDefined(tv) {
      return CMR_Text(tv.GetDevicePS().GetChannelName(j), "Channel " + IntToString(j + 1));
    }
    return "";
  }

  public final func Tune(i: Int32, j: Int32) -> Bool {
    let d: ref<Device> = this.At(i);
    let radio: ref<Radio>;
    let tv: ref<TV>;
    if !IsDefined(d) || !this.Usable(d) { return false; }
    radio = d as Radio;
    if IsDefined(radio) {
      if j < 0 || j >= RadioStationDataProvider.GetStationsCount() { return false; }
      radio.GetDevicePS().CMR_Tune(RadioStationDataProvider.GetRadioStationByUIIndex(j));
      return true;
    }
    tv = d as TV;
    if IsDefined(tv) {
      tv.GetDevicePS().CMR_Tune(j);
      if tv.GetDevicePS().IsON() { MediaRemoteSystem.ReapplyLater(tv, 0.7); }
      return true;
    }
    return false;
  }

  public final func Step(i: Int32, dir: Int32) -> Bool {
    let d: ref<Device> = this.At(i);
    let radio: ref<Radio>;
    let tv: ref<TV>;
    let rps: ref<RadioControllerPS>;
    let tps: ref<TVControllerPS>;
    let cur: Int32;
    let n: Int32;
    if !IsDefined(d) || !this.Usable(d) { return false; }
    radio = d as Radio;
    if IsDefined(radio) {
      rps = radio.GetDevicePS();
      cur = rps.GetActiveStationIndex();
      if cur < 0 {
        rps.CMR_Tune(RadioStationDataProvider.GetRadioStationByUIIndex(0));
      } else {
        if dir >= 0 {
          rps.CMR_Tune(RadioStationDataProvider.GetNextStationTo(cur));
        } else {
          rps.CMR_Tune(RadioStationDataProvider.GetPreviousStationTo(cur));
        }
      }
      return true;
    }
    tv = d as TV;
    if IsDefined(tv) {
      tps = tv.GetDevicePS();
      n = tps.CMR_ChannelCount();
      if n <= 0 { return false; }
      cur = tps.GetActiveStationIndex();
      cur = dir >= 0 ? (cur + 1) % n : (cur - 1 + n) % n;
      tps.CMR_Tune(cur);
      if tps.IsON() { MediaRemoteSystem.ReapplyLater(tv, 0.7); }
      return true;
    }
    return false;
  }

  public final func SetLevel(i: Int32, level: Int32) -> Bool {
    let d: ref<Device> = this.At(i);
    let radio: ref<Radio>;
    let tv: ref<TV>;
    let old: Int32;
    if !IsDefined(d) || !this.Usable(d) { return false; }
    level = Clamp(level, 0, 100);
    old = this.LevelOf(d.GetEntityID());
    if level == old { return true; }
    this.StoreLevel(d.GetEntityID(), level);
    radio = d as Radio;
    if IsDefined(radio) {
      if !radio.GetDevicePS().IsON() {
        if level >= 100 && old < 100 { radio.CMR_Apply(100, true); }   // 1.0.3: reset now, nothing else will
        return true;
      }
      if level > 0 && old <= 0 {
        radio.CMR_Replay();
      }
      radio.CMR_Apply(level, true);
      return true;
    }
    tv = d as TV;
    if IsDefined(tv) {
      tv.CMR_Apply(level, true);
      return true;
    }
    return false;
  }

  // One line for the remote keys' on-screen note.
  public final func Describe(i: Int32) -> String {
    let e: ref<MediaRemoteEntry> = this.Entry(i);
    if !IsDefined(e) { return ""; }
    if !e.usable { return e.name + ": " + e.reason; }
    if !e.isOn { return e.name + ": off"; }
    return e.name + ": " + e.station + " - " + (e.level <= 0 ? "muted" : IntToString(e.level) + " %");
  }

  public final func Toast(text: String) -> Void {
    let msg: SimpleScreenMessage;
    msg.isShown = true;
    msg.duration = 2.0;
    msg.message = text;
    msg.type = SimpleMessageType.Neutral;
    GameInstance.GetBlackboardSystem(this.GetGameInstance())
      .Get(GetAllBlackboardDefs().UI_Notifications)
      .SetVariant(GetAllBlackboardDefs().UI_Notifications.OnscreenMessage, ToVariant(msg), true);
  }
}

// ---------------------------------------------------------------------------------------------------
// Helpers

public static func CMR_Text(key: String, fallback: String) -> String {
  let t: String;
  if StrLen(key) == 0 { return fallback; }
  t = GetLocalizedText(key);
  if StrLen(t) == 0 || StrBeginsWith(t, "LocKey#") || StrBeginsWith(t, "Gameplay-") { return fallback; }
  return t;
}

public static func CMR_StationText(station: ERadioStationList) -> String {
  return CMR_Text(RadioStationDataProvider.GetChannelName(station), NameToString(RadioStationDataProvider.GetStationName(station)));
}

// Sets a Wwise game parameter on one device, both ways the engine routes it: directly on the named
// emitter and as a queued event (the path vanilla's mute_tv_emitter takes).
public static func CMR_Param(obj: ref<GameObject>, name: CName, value: Float, emitter: CName) -> Void {
  if IsNameValid(emitter) {
    GameInstance.GetAudioSystem(obj.GetGame()).Parameter(name, value, obj.GetEntityID(), emitter);
  } else {
    GameInstance.GetAudioSystem(obj.GetGame()).Parameter(name, value, obj.GetEntityID());
  }
  GameObject.SetAudioParameter(obj, name, value);
}

// NC Finance / Living Costs: at home with services cut, media devices are dead to the hand; same for the remote.
@if(ModuleExists("NightCityFinance.Amenities"))
public static func CMR_ServicesCut(game: GameInstance) -> Bool {
  return NCFAmenitiesRules.ServicesCut(game);
}

@if(!ModuleExists("NightCityFinance.Amenities"))
public static func CMR_ServicesCut(game: GameInstance) -> Bool {
  return false;
}

// ---------------------------------------------------------------------------------------------------
// Device side

@addMethod(RadioControllerPS)
public final func CMR_Tune(station: ERadioStationList) -> Void {
  this.m_previousStation = this.m_activeStation;
  this.m_activeStation = EnumInt(station);
  this.m_dataInitialized = true;
  this.m_activeChannelName = RadioStationDataProvider.GetChannelName(station);
  // Off: only preset the station, vanilla's QuestSetChannel would start playing on a switched-off radio.
  if this.IsON() {
    this.ExecutePSAction(this.ActionQuestSetChannel());
  }
}

@addMethod(TVControllerPS)
public final func CMR_ChannelCount() -> Int32 {
  return ArraySize(this.m_tvSetup.m_channels);
}

@addMethod(TVControllerPS)
public final func CMR_Tune(idx: Int32) -> Void {
  if idx < 0 || idx >= ArraySize(this.m_tvSetup.m_channels) { return; }
  this.GetActiveStationIndex();
  this.SetActiveStationIndex(idx);
  this.PassChannelName(this.m_tvSetup.m_channels[idx].channelName);
  if this.IsON() {
    this.ExecutePSAction(this.ActionQuestSetChannel());
  }
}

@addMethod(Radio)
public final func CMR_Replay() -> Void {
  this.PlayGivenStation();
}

// level 0: silent, 100: vanilla. reset = also write the 100 % values (after a change back to 100).
@addMethod(Radio)
public final func CMR_Apply(level: Int32, reset: Bool) -> Void {
  let cut: Float;
  let f: Float;
  let focus: Float = 0.0;
  let vo: Float = 0.0;
  let occl: Float = 0.0;
  if level <= 0 {
    GameObject.AudioSwitch(this, n"radio_station", n"station_none", n"radio");
    return;
  }
  if level >= 100 && !reset { return; }
  if level < 100 {
    cut = (1.0 - Cast<Float>(level) / 100.0) * 19.0;
    // focus_mode curve: 0 -> 0 dB, 0.16038 -> -2.1 dB, 1 -> -5 dB
    f = MinF(cut, 5.0);
    focus = f <= 2.1 ? 0.16038 * f / 2.1 : 0.16038 + (f - 2.1) / 2.9 * 0.83962;
    cut -= f;
    // vo_dialog_active: 0 -> 0 dB, 1 -> -2 dB
    f = MinF(cut, 2.0);
    vo = f / 2.0;
    cut -= f;
    // game_occlusion: 0 -> 0 dB, 1 -> -12 dB
    occl = MinF(cut, 12.0) / 12.0;
  }
  CMR_Param(this, n"focus_mode", focus, n"radio");
  CMR_Param(this, n"vo_dialog_active", vo, n"radio");
  CMR_Param(this, n"game_occlusion", occl, n"radio");
}

@addMethod(TV)
public final func CMR_Apply(level: Int32, reset: Bool) -> Void {
  let ps: ref<TVControllerPS> = this.GetDevicePS();
  let g: Float;
  if !IsDefined(ps) || ps.IsInterfaceMuted() || !ps.IsON() { return; }
  if level >= 100 && !reset { return; }
  g = ClampF(Cast<Float>(level) / 100.0, 0.0, 1.0);
  CMR_Param(this, n"tv_receiver_volume", g * g, n"");
}

// Registration: every radio / TV that resolves its state (stream-in, near V) joins the list.
@wrapMethod(Radio)
protected func ResolveGameplayState() -> Void {
  wrappedMethod();
  let sys: ref<MediaRemoteSystem> = MediaRemoteSystem.Get(this.GetGame());
  if IsDefined(sys) { sys.Register(this); }
}

@wrapMethod(TV)
protected func ResolveGameplayState() -> Void {
  wrappedMethod();
  let sys: ref<MediaRemoteSystem> = MediaRemoteSystem.Get(this.GetGame());
  if IsDefined(sys) { sys.Register(this); }
}

// Saved radio volume comes back with every station start (turn on, stream-in, tuning).
@wrapMethod(Radio)
private final func PlayGivenStation() -> Void {
  wrappedMethod();
  let level: Int32 = MediaRemoteSystem.LevelFor(this);
  if level < 100 {
    this.CMR_Apply(level, false);
  }
}

// A quest / scene unmute plays unmute_tv_emitter (back to full): put the saved level back after its fade.
@wrapMethod(TV)
protected cb func OnQuestMuteSounds(evt: ref<QuestMuteSounds>) -> Bool {
  let r: Bool = wrappedMethod(evt);
  let ps: ref<TVControllerPS> = this.GetDevicePS();
  if IsDefined(ps) && !ps.IsInterfaceMuted() && MediaRemoteSystem.LevelFor(this) < 100 {
    MediaRemoteSystem.ReapplyLater(this, 0.7);
  }
  return r;
}

// Saved TV volume: skip vanilla's unmute fade to full (it would blare for half a second), go straight to the level.
@wrapMethod(TV)
protected func TurnOnScreen() -> Void {
  let ps: ref<TVControllerPS> = this.GetDevicePS();
  let level: Int32 = MediaRemoteSystem.LevelFor(this);
  if level >= 100 || !IsDefined(ps) || ps.IsInterfaceMuted() {
    wrappedMethod();
    return;
  }
  ps.SetInterfaceMuted(true);
  wrappedMethod();
  ps.SetInterfaceMuted(false);
  this.CMR_Apply(level, false);
  MediaRemoteSystem.ReapplyLater(this, 0.7);
}
