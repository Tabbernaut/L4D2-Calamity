#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4downtown>
#include <l4d2_penalty_bonus>
#include <timers>
#undef REQUIRE_PLUGIN
#include <confogl>
#define REQUIRE_PLUGIN

#define PLUGIN_VERSION              "0.5.1"

#define STR_MAX_CLASSNAME           64
#define TEAM_SURVIVOR               2
#define TEAM_INFECTED               3
#define TEAM_A                      0
#define TEAM_B                      1
#define ZC_SMOKER                   1
#define ZC_BOOMER                   2
#define ZC_HUNTER                   3
#define ZC_SPITTER                  4
#define ZC_JOCKEY                   5
#define ZC_CHARGER                  6
#define ZC_WITCH                    7
#define ZC_TANK                     8
#define TANK_HEALTH_FACTOR          1.5
#define SCORE_TYPE_ROUND            0
#define SCORE_TYPE_CAMPAIGN         1
#define DOOR_UNLOCK                 0
#define DOOR_LOCK                   1
#define DOOR_CLOSED                 0
#define DOOR_OPENING                1
#define DOOR_OPEN                   2
#define DOOR_CLOSING                3
#define DISPLAYDELAYTIME            0.5
#define ROUNDENDDELAYTIME           1.0
#define SCORESDELAYTIME             0.025
#define TANKCHECKTIME               0.1
#define RUSHCHECKTIME               1.0

#define MAX_SURVIVORS               6
#define MAX_MESSAGE_LENGTH          256

#define DT3_EVENTBUTTON             "button_safedoor_PANIC"
#define DT3_EVENTTIME               120.0


static const String:CLASSNAME_WITCH[] = "witch";

// CVars
new         Handle:                 hPluginEnabled                  = INVALID_HANDLE;
new         Handle:                 hBonusWitch                     = INVALID_HANDLE;
new         Handle:                 hBonusWitchCrown                = INVALID_HANDLE;
new         Handle:                 hBonusTank                      = INVALID_HANDLE;
new         Handle:                 hBonusTankPercent               = INVALID_HANDLE;
new         Handle:                 hDoorBlockTank                  = INVALID_HANDLE;
new         Handle:                 hDoorBlockRush                  = INVALID_HANDLE;
new         Handle:                 hFreezeDistTank                 = INVALID_HANDLE;
new         Handle:                 hFreezeDistRush                 = INVALID_HANDLE;
new         Handle:                 hFreezeDistNotify               = INVALID_HANDLE;
new         Handle:                 hRushThreshold                  = INVALID_HANDLE;
new         Handle:                 hDT3EventBonus                  = INVALID_HANDLE;
new         Handle:                 hCvarTankHealth                 = INVALID_HANDLE;
new         Handle:                 hCvarMaxIncaps                  = INVALID_HANDLE;

// Internal vars
new         bool:                   bLateLoad;
new         bool:                   bBeforeMapStart                 = true;                                             // before the first round actually starts
new         bool:                   bTeamAFirst                     = true;                                             // whether team A went survivor first this round
new                                 iTeamPlaying                    = 0;                                                // which of team a=0,b=1 is currently survivor?
new         bool:                   bInRound;                                                                           // are we currently in round?
new                                 iRoundNumber;                                                                       // no. of round played (0 or 1)

new         bool:                   bWitchBungled                   = false;                                            // whether witch was allowed to do damage this roundhalf
new         bool:                   bWitchGotKill                   = false;                                            // whether witch got her kill on a survivor
new         bool:                   bHurtWitch[MAXPLAYERS+1]        = {false,...};                                      // which players hurt the witch?
new         bool:                   bTankSpawned                    = false;                                            // whether tank has spawned for this roundhalf
new                                 iTankClient                     = false;                                            // who is tank?

new                                 iBonusShow[2];                                                                      // each team's bonus, but is not unset until actual round end

// Rush protection
new                                 iDistance                       = 0;                                                // this maps (normal) full distance
new                                 iSafeDoorEntity                 = 0;                                                // what entity is the exit saferoom door?
new         bool:                   bSafeDoorBlocked                = false;                                            // saferoom door blocked from being used?
new        bool:                    bRushProtection                 = false;                                            // whether distance is frozen because of rush-protection

// DT3 stuff
new        bool:                    bDT3                            = false;                                            // if we're in death toll 3, this is true
new        bool:                    bDT3Started                     = false;                                            // event started for this round?
new        Float:                   fDT3StartTime;                                                                      // when the DT3 event was started
new        Float:                   fDT3SurvivorLasted[MAXPLAYERS+1];                                                   // per survivor: the time they lasted before dying during the event

new        bool:                    bCheckWipeDone                  = false;
new        bool:                    bCheckWipeTankDone              = false;

// SDK-Stuff
new                                 iOffset_Incapacitated           = 0;                                                // used to check if tank is dying


/* -------------------------------
 *            Init
 * ------------------------------- */

public Plugin:myinfo =
{
    name = "Calamity bonus scoring system",
    author = "Tabun",
    description = "Changes scoring system. Adds bonuses for killing tank/witch.",
    version = PLUGIN_VERSION,
    url = "https://github.com/Tabbernaut/L4D2-Calamity"
}

public APLRes:AskPluginLoad2( Handle:plugin, bool:late, String:error[], errMax)
{
    bLateLoad = late;
    return APLRes_Success;
}

public OnPluginStart()
{

    if ( bLateLoad )
    {
        for (new i=1; i <= MAXPLAYERS; i++)
        {
            if (IsClientAndInGame(i))
            {
                SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage);
            }
        }
        
        FindExitDoor();
    }

    // Cvars
    hPluginEnabled = CreateConVar(      "sm_calamitybonus_enabled",         "1",     "Enable calamity scoring changes.", FCVAR_PLUGIN, true, 0.0, true, 1.0);
    hBonusWitch = CreateConVar(         "sm_calamitybonus_witch",           "0",     "How many points for killing witch.", FCVAR_PLUGIN, true, 0.0);
    hBonusWitchCrown = CreateConVar(    "sm_calamitybonus_witchcrown",      "5",     "How many extra points for killing witch without any incaps.", FCVAR_PLUGIN, true, 0.0);
    hBonusTank = CreateConVar(          "sm_calamitybonus_tank",           "20",     "How many points for killing tank.", FCVAR_PLUGIN, true, 0.0);
    hBonusTankPercent = CreateConVar(   "sm_calamitybonus_tankpercent",     "1",     "If set to 1, gives a percentage of tank-kill bonus equal to damage done to tank vs. its full health.", FCVAR_PLUGIN, true, 0.0, true, 1.0);
    hDoorBlockTank = CreateConVar(      "sm_calamity_doorblock_tank",       "1",     "Whether to prevent saferoom door usage while tank is alive.", FCVAR_PLUGIN, true, 0.0, true, 1.0);
    hDoorBlockRush = CreateConVar(      "sm_calamity_doorblock_rush",       "1",     "Whether to prevent saferoom door usage while one survivor is rushing ahead of incapped teammates.", FCVAR_PLUGIN, true, 0.0, true, 1.0);
    hFreezeDistTank = CreateConVar(     "sm_calamity_freezedist_tank",      "1",     "Whether to freeze distance points while tank is alive.", FCVAR_PLUGIN, true, 0.0, true, 1.0);
    hFreezeDistRush = CreateConVar(     "sm_calamity_freezedist_rush",      "1",     "Whether to freeze distance points when one survivor is rushing ahead of incapped teammates.", FCVAR_PLUGIN, true, 0.0, true, 1.0);
    hFreezeDistNotify = CreateConVar(   "sm_calamity_freezedist_notify",    "0",     "Whether to announce rush protection distance freezing.", FCVAR_PLUGIN, true, 0.0, true, 1.0);
    hRushThreshold = CreateConVar(      "sm_calamity_rushthreshold",        "1",     "Freeze distance points when this many survivors are up and anyone is incapped.", FCVAR_PLUGIN, true, 1.0);
    hDT3EventBonus = CreateConVar(      "sm_calamity_dt3_event",           "15",     "Bonus points for making it through full event (0 disables scoring change).", FCVAR_PLUGIN, true, 0.0);
    hCvarTankHealth = FindConVar(       "z_tank_health");
    hCvarMaxIncaps = FindConVar(        "survivor_max_incapacitated_count");

    // Events
    HookEvent("round_start",            Event_RoundStart,           EventHookMode_PostNoCopy);
    HookEvent("round_end",              Event_RoundEnd,             EventHookMode_PostNoCopy);
    HookEvent("finale_win",             Event_RoundEnd,             EventHookMode_PostNoCopy);
    HookEvent("mission_lost",           Event_RoundEnd,             EventHookMode_PostNoCopy);
    HookEvent("map_transition",         Event_RoundEnd,             EventHookMode_PostNoCopy);
    HookEvent("witch_spawn",            Event_WitchSpawned,         EventHookMode_Post);
    HookEvent("witch_killed",           Event_WitchKilled,          EventHookMode_Post);
    HookEvent("infected_hurt",          Event_InfectedHurt,         EventHookMode_Post);
    HookEvent("tank_spawn",             Event_TankSpawned,          EventHookMode_Post);
    HookEvent("player_death",           Event_PlayerKilled,         EventHookMode_Post);
    HookEvent("player_use",             Event_PlayerUse,            EventHookMode_Pre);
    HookEvent("player_incapacitated",   Event_PlayerIncap,          EventHookMode_Post);
    HookEvent("player_ledge_grab",      Event_PlayerHang,           EventHookMode_Post);
    HookEvent("door_open",              Event_DoorOpen,             EventHookMode_Post);

    // Commands
    RegConsoleCmd("sm_bonus", Cmd_Bonus, "Show bonus for current team.");

    // Addresses
    iOffset_Incapacitated = FindSendPropInfo("Tank", "m_isIncapacitated");
}

public OnClientPostAdminCheck(client)
{
        SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public Action:Cmd_ResetScores(client, args)
{
    for (new x=0; x<2; x++)
    {
        iBonusShow[x] = 0;
    }
}

public Action:Cmd_Bonus(client, args)
{
    if ( IsClientAndInGame(client) )
    {
        PrintToChat( client,"\x01[calamity] Round bonus:\x04 %d \x01", iBonusShow[iTeamPlaying] );
    }
    else
    {
        PrintToServer( "\x01[calamity] Round bonus:\x04 %d \x01", iBonusShow[iTeamPlaying] );
    }
}



stock bool:L4D2_AreTeamsFlipped()
{
    return bool:( GameRules_GetProp("m_bAreTeamsFlipped") );
}

public Action:delayedMessage(Handle:timer, any:pack)
{
    decl String: buffer[MAX_MESSAGE_LENGTH];

    ResetPack(pack);
    ReadPackString(pack, buffer, sizeof(buffer));
    PrintToChatAll("\x01%s", buffer);
}


/* -------------------------------
 *            Round start / end
 * ------------------------------- */

public OnMapStart()
{
    if ( bBeforeMapStart )
    {
        bBeforeMapStart = false;
        bInRound = true;
        iRoundNumber = 0;
        bWitchBungled = false;
        bWitchGotKill = false;
        bTankSpawned = false;
        bRushProtection = false;
        iTankClient = 0;

        if ( bDT3 )
        {
            bDT3Started = false;
            for ( new i = 1; i <= MaxClients; i++ )
            {
                fDT3SurvivorLasted[i] = 0.0;
            }
        }

        ClearHurtWitch();
        FindExitDoor();
        UnBlockDoor();

        // if DT3, set cvar(s)
        new String:sMapName[64];
        GetCurrentMap( sMapName, sizeof(sMapName) );
        
        bDT3 = bool:( StrEqual(sMapName, "c10m3_ranchhouse") );

        for ( new x = 0; x < 2; x++ )
        {
            iBonusShow[x] = 0;
        }
        // remember normal distance for this map
        iDistance = LGO_GetMapValueInt( "max_distance", iDistance );

        // remember whether team A is roundhalf 0 survivor
        bTeamAFirst = !L4D2_AreTeamsFlipped();
        iTeamPlaying = GetCurrentSurvivorTeam();
    }
}

public OnMapEnd()
{
    iRoundNumber = 0;
    bInRound = false;
    bBeforeMapStart = true;
}

public Action:Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
    // only do this for the 2nd roundhalf (it gets called before mapstart)
    if ( bBeforeMapStart ) { return; }

    bWitchBungled = false;
    bWitchGotKill = false;
    bTankSpawned = false;
    bRushProtection = false;
    bCheckWipeDone = false;
    bCheckWipeTankDone = false;
    iTankClient = 0;    

    if ( bDT3 )
    {
        bDT3Started = false;
        for ( new i=1; i <= MaxClients; i++ )
        {
            fDT3SurvivorLasted[i] = 0.0;
        }
    }

    ClearHurtWitch();
    FindExitDoor();                                                 // needs to be done every round, apparently it gets reassigned
    UnBlockDoor();

    if ( !bInRound )
    {
        bInRound = true;
        iRoundNumber++;
        L4D_SetVersusMaxCompletionScore(iDistance);                 // reset full distance for second team
        iTeamPlaying = GetCurrentSurvivorTeam();
    }
}

// penalty_bonus: requesting final update before setting score, pass it the holdout bonus
public PBONUS_RequestFinalUpdate( &update )
{
    if ( bDT3Started && !bCheckWipeDone )
    {
        update += CheckWipe();
    }
    
    if ( !bCheckWipeTankDone )
    {
        update += CheckTankWipeBonus();
    }
    
    return update;
}

// this is not called before penalty_bonus, so useless
public Action:L4D2_OnEndVersusModeRound(bool:countSurvivors)
{
    if ( bDT3Started && !bCheckWipeDone )
    {
        CheckWipe();
    }
    
    // just in case this happens before the scores are written (never in testing)
    if ( !bCheckWipeTankDone )
    {
        CheckTankWipeBonus();
    }
}

public Action:Event_RoundEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
    if ( bInRound )
    {
        // do stuff when the round is done "the first time"
        bInRound = false;

        // if rushprotection was enabled (and thus it was a wipe), reset distance points
        L4D_SetVersusMaxCompletionScore(iDistance);

        new Handle: pack;
        decl String: buffer[MAX_MESSAGE_LENGTH];
        Format( buffer, sizeof(buffer), "\x01[calamity] Total round bonus:\x04 %d\x01.", iBonusShow[iTeamPlaying] );
        CreateDataTimer( ROUNDENDDELAYTIME, delayedMessage, pack );
        WritePackString(pack, buffer);
    }
}

/* --------------------------------------
 *            Incap checks (rushprotection)
 * -------------------------------------- */

public Action:Event_PlayerHang(Handle:event, const String:name[], bool:dontBroadcast)
{
    if ( !bRushProtection )
    {
        CheckRushProtection();
    }
}

public Action:Event_PlayerIncap(Handle:event, const String:name[], bool:dontBroadcast)
{
    if ( !bRushProtection )
    {
        CheckRushProtection();
    }
}

public Action:CheckRushProtection()
{
    // check if only 1 is up, but others not dead
    if ( IsSurvivorRushing() && GetConVarBool(hFreezeDistRush) )
    {
        bRushProtection = true;
        L4D_SetVersusMaxCompletionScore(0);

        if ( GetConVarBool(hDoorBlockRush) )
        {
            BlockDoor();
        }
        
        if ( !bTankSpawned )
        {
            if (GetConVarBool( hFreezeDistNotify) )
            {
                PrintToChatAll( "\x01[calamity] Rush protection: distance frozen." );
            }
        }
        else
        {
            PrintToServer( "\x01[calamity] Suppresed rushprotection enabled message during tankfight." );
        }
        CreateTimer(RUSHCHECKTIME, Timer_CheckRush, _, TIMER_REPEAT);
    }
}

public Action:Timer_CheckRush(Handle:timer)
{
    // do an interval timer to see if player is still rushing
    // if more than 1 survivor up, disable rush protection (all dead is no prob, that's just round end)

    if ( bRushProtection && !IsSurvivorRushing() )
    {
        bRushProtection = false;

        // check if tank is up!
        if ( bTankSpawned && GetConVarBool(hFreezeDistTank) )
        {
            //PrintToChatAll("\x01[calamity] Rushprotection removed. Tank still freezes distance.");
            PrintToServer( "\x01[calamity] Suppresed rushprotection disabled message during tankfight." );
            return Plugin_Stop;
        }
        L4D_SetVersusMaxCompletionScore(iDistance);
        UnBlockDoor();

        if (GetConVarBool(hFreezeDistNotify))
        {
            PrintToChatAll("\x01[calamity] Rushprotection removed.");
        }
        return Plugin_Stop;
    }
    else if ( !bRushProtection )
    {
        // should never happen, but stop timer just in case
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

/* --------------------------------------
 *            Saferoom doors
 * -------------------------------------- */

public FindExitDoor()
{
    new entity = -1;
    while( (entity = FindEntityByClassname(entity, "prop_door_rotating_checkpoint")) != -1 )
    {
        // this gives errors (on some maps), maybe do some sort of check?
        if ( GetEntProp(entity, Prop_Data, "m_hasUnlockSequence") == DOOR_UNLOCK )
        {
            iSafeDoorEntity = entity;
        }
    }
}

public Action:Event_PlayerUse(Handle:event, const String:name[], bool:dontBroadcast)
{
    new client = GetClientOfUserId(GetEventInt(event, "userid"));
    new entity = GetEventInt(event, "targetid");

    if ( !IsValidEntity(entity) ) { return Plugin_Continue; }

    // DT3 scoring check
    if ( bDT3 && GetConVarFloat(hDT3EventBonus) && !bDT3Started )
    {
        new String:entityName[64];
        GetEntPropString(entity, Prop_Data, "m_iName", entityName, sizeof(entityName));

        if ( StrEqual(entityName, DT3_EVENTBUTTON) )
        {
            bDT3Started = true;
            fDT3StartTime = GetTickedTime();
        }
    }

    if ( entity != iSafeDoorEntity ) { return Plugin_Continue; }
    
    // tell player what's going on if blocked?
    if ( bSafeDoorBlocked )
    {
        // check if the conditions still apply, otherwise unlock door
        new tankBlock = GetConVarBool(hDoorBlockTank);
        new rushBlock = GetConVarBool(hDoorBlockRush);

        // unblock when tank was kicked or glitched out -- or cvar changed -- and no other conditions apply
        if ( (!GetTankClient() || !tankBlock) && (!bRushProtection || !rushBlock) )
        {
            UnBlockDoor();
            return Plugin_Continue;
        }

        if ( IsClientAndInGame(client) )
        {
            decl String: buffer[MAX_MESSAGE_LENGTH];
            Format( buffer, sizeof(buffer), "%s", (bRushProtection) ? "Help your teammates first!" : ((tankBlock) ? "Kill tank first!" : "(MAGIC HAPPENS? WHUT?)") );
            PrintToChat(client, "\x01[calamity] Can't use saferoom door. %s", buffer);
        }
    }

    return Plugin_Continue;
}


public BlockDoor()
{
    if ( bSafeDoorBlocked )
    {
        return;
    }

    // if open, keep open.. if closed.. keep closed
    new entity = iSafeDoorEntity;
    if ( !entity || !IsValidEntity(entity) )
    {
        return;
    }

    new doorState = GetEntProp(entity, Prop_Data, "m_eDoorState");

    AcceptEntityInput(entity, "Lock");
    if ( doorState == DOOR_CLOSED || doorState == DOOR_CLOSING )
    {
        AcceptEntityInput(entity, "ForceClosed");
    }
    else
    {
        AcceptEntityInput(entity, "ForceOpen");
    }
    SetEntProp(entity, Prop_Data, "m_hasUnlockSequence", DOOR_LOCK);

    //PrintToChatAll("\x01[calamity] Saferoom door blocked.");

    bSafeDoorBlocked = true;
}

public UnBlockDoor()
{
    if ( !bSafeDoorBlocked ) { return; }

    // unlock the door
    new entity = iSafeDoorEntity;
    if ( !entity || !IsValidEntity(entity) )
    {
        return;
    }

    decl String:tmpClassName[STR_MAX_CLASSNAME];

    GetEntityClassname(entity, tmpClassName, sizeof(tmpClassName));
    if ( !StrEqual(tmpClassName, "prop_door_rotating_checkpoint") )
    {
        FindExitDoor();
        entity = iSafeDoorEntity;

        if ( !entity || !IsValidEntity(entity) )
        {
            return;
        }
    }
    AcceptEntityInput(entity, "Unlock");
    SetEntProp(entity, Prop_Data, "m_hasUnlockSequence", DOOR_UNLOCK);
    //PrintToChatAll("\x01[calamity] Saferoom door unblocked.");

    bSafeDoorBlocked = false;
}

public ControlDoor(entity, operation)
{
    if (operation == DOOR_LOCK)
    {
        /* Close and lock */
        AcceptEntityInput(entity, "Close");
        AcceptEntityInput(entity, "Lock");
        AcceptEntityInput(entity, "ForceClosed");
        SetEntProp(entity, Prop_Data, "m_hasUnlockSequence", DOOR_LOCK);
    }
    else
    {
        /* Unlock and open */
        SetEntProp(entity, Prop_Data, "m_hasUnlockSequence", DOOR_UNLOCK);
        AcceptEntityInput(entity, "Unlock");
        AcceptEntityInput(entity, "ForceClosed");
        AcceptEntityInput(entity, "Open");
    }
}


/* --------------------------------------
 *            DT3 scoring change
 * -------------------------------------- */

public Action:Event_DoorOpen(Handle:event, const String:name[], bool:dontBroadcast)
{
    if (    !GetEventBool(event, "checkpoint") ||
            !bDT3 ||
            !bDT3Started ||
            !GetConVarFloat(hDT3EventBonus)
    ) {
        return;
    }

    // event started, checkpoint door opens, so event is definitely over
    // DT3 scoring: how far through event did they make it?

    new iSurv = 0;
    new Float: fTotalTime = 0.0;

    for ( new i = 1; i <= MaxClients; i++ )
    {
        if ( IsSurvivor(i) )
        {
            iSurv++;
            if (IsPlayerAlive(i))
            {
                fDT3SurvivorLasted[i] = DT3_EVENTTIME;
            }
            else
            {
                if ( fDT3SurvivorLasted[i] > DT3_EVENTTIME )
                {
                    fDT3SurvivorLasted[i] = DT3_EVENTTIME;
                }
            }
            fTotalTime += fDT3SurvivorLasted[i];
        }
    }

    new Float:fBonusFactor = 0.0;
    if (iSurv)
    fBonusFactor = fTotalTime / (iSurv * DT3_EVENTTIME);

    new tmpBonus = RoundFloat(GetConVarFloat(hDT3EventBonus) * fBonusFactor);

    PBONUS_AddRoundBonus( tmpBonus );
    iBonusShow[iTeamPlaying] += tmpBonus;

    PrintToChatAll( "\x01[Church event] Event survival time bonus:\x04 %d \x01", tmpBonus );
    bDT3Started = false;
}

// this is called whenever someone gets incapped/ledgehung or dies -- if no one is left standing, it's a wipe (pre-score-set)
stock CheckWipe ()
{
    new tmpBonus = 0;
    
    if ( !bDT3 || !bDT3Started )
    {
        return 0;
    }

    if ( !GetUprightSurvivors() )
    {
        // it's a wipe, check the event progress
        new iSurv = 0;
        new Float: fTotalTime = 0.0;

        for ( new i = 1; i <= MaxClients; i++ )
        {
            if ( IsSurvivor(i) )
            {
                iSurv++;
                if ( fDT3SurvivorLasted[i] > DT3_EVENTTIME )
                {
                    fDT3SurvivorLasted[i] = DT3_EVENTTIME;
                }
                if ( IsPlayerAlive(i) && !fDT3SurvivorLasted[i] )
                {
                    fDT3SurvivorLasted[i] = GetTickedTime() - fDT3StartTime;
                }
                fTotalTime += fDT3SurvivorLasted[i];
            }
        }

        new Float:fBonusFactor = 0.0;
        if ( iSurv )
        {
            fBonusFactor = fTotalTime / (iSurv * DT3_EVENTTIME);
        }

        tmpBonus = RoundFloat( GetConVarFloat(hDT3EventBonus) * fBonusFactor );

        PBONUS_AddRoundBonus( tmpBonus );
        iBonusShow[iTeamPlaying] += tmpBonus;

        PrintToChatAll( "\x01[Church event] Event survival time bonus:\x04 %d \x01", tmpBonus );
        bDT3Started = false;
    }
    
    bCheckWipeDone = true;
    
    return tmpBonus;
}

/* --------------------------------------
 *            Witch
 * -------------------------------------- */

public Action:Event_WitchSpawned(Handle:event, const String:name[], bool:dontBroadcast)
{
    bWitchBungled = false;
    bWitchGotKill = false;
    ClearHurtWitch();
}

public Action:Event_InfectedHurt(Handle:event, const String:name[], bool:dontBroadcast)
{
    if ( !GetConVarBool(hPluginEnabled) ) { return Plugin_Continue; }

    // catch damage done to witch
    new victimEntId = GetEventInt(event, "entityid");

    if ( IsWitch(victimEntId) )
    {
        new attacker = GetClientOfUserId( GetEventInt(event, "attacker") );

        if ( !attacker )
        {
            return Plugin_Continue;
        }

        if ( IsClientAndInGame(attacker) && GetClientTeam(attacker) == TEAM_SURVIVOR )
        {
            bHurtWitch[attacker] = true;
        }
    }
    return Plugin_Continue;
}

public Action: Event_WitchKilled(Handle:event, const String:name[], bool:dontBroadcast)
{
    if ( !GetConVarBool(hPluginEnabled) ) { return Plugin_Continue; }

    new tmpBonus = 0;
    if ( !bWitchGotKill )
    {
        // normal killing bonus
        tmpBonus = GetConVarInt(hBonusWitch);
    }
    if ( !bWitchGotKill && !bWitchBungled )
    {
        // bonus for not taking a hit for witch
        tmpBonus += GetConVarInt(hBonusWitchCrown);
    }
    
    if ( tmpBonus )
    {
        // check how many people shot her.. if 2, halve bonus.. any more = 0 bonus
        new iHurtWitch = GetHurtWitch();

        if (iHurtWitch == 1)
        {
            // nothing, no report
        }
        else if (iHurtWitch == 2)
        {
            tmpBonus = RoundFloat(0.5 * float(tmpBonus));
            PrintToChatAll( "\x01[calamity] Two players damaged witch, bonus halved." );
        }
        else
        {
            tmpBonus = 0;
            PrintToChatAll( "\x01[calamity] More than two players damaged witch, bonus denied." );
        }
    }

    if ( tmpBonus )
    {
        PBONUS_AddRoundBonus( tmpBonus );
        iBonusShow[iTeamPlaying] += tmpBonus;

        new Handle: pack;
        decl String: buffer[MAX_MESSAGE_LENGTH];
        Format( buffer, sizeof(buffer), "\x01[calamity] Team %s gets\x04 %d \x01bonus points for handling witch.", ((iTeamPlaying)?"B":"A"), tmpBonus );
        CreateDataTimer(DISPLAYDELAYTIME, delayedMessage, pack);
        WritePackString(pack, buffer);
    }
    return Plugin_Continue;
}

public Action:OnTakeDamage(victim, &attacker, &inflictor, &Float:damage, &damagetype)
{
    if ( !GetConVarBool(hPluginEnabled) ) { return Plugin_Continue; }
    if ( !inflictor || !attacker || !victim || !IsValidEdict(victim) || !IsValidEdict(inflictor) ) { return Plugin_Continue; }

    decl String:classname[64];
    new bool:bIsWitchAttack = false;

    if ( !IsClientAndInGame(attacker) )
    {
        GetEdictClassname( inflictor, classname, sizeof(classname) );
        bIsWitchAttack = bool:( StrEqual(classname, CLASSNAME_WITCH) );
    }
    
    // only look at witches for this
    if ( !bIsWitchAttack ) { return Plugin_Continue; }

    new teamvictim;
    new bool:bHumanVictim = IsClientAndInGame(victim);

    // case: attacker witch or common, victim human player
    if ( bHumanVictim )
    {
        teamvictim = GetClientTeam(victim);
        if ( teamvictim == TEAM_SURVIVOR )
        {
            if ( bIsWitchAttack )
            {
                if ( damage > 0 )
                {
                    bWitchBungled = true;
                }

                new propIncaps = FindSendPropInfo("CTerrorPlayer", "m_currentReviveCount");
                new iIncapCount = GetEntData(victim, propIncaps, 1);
                new iMaxIncaps = GetConVarInt(hCvarMaxIncaps);

                // if it is even a death, then it's worse
                if ( (IsIncapped(victim) || iIncapCount >= iMaxIncaps) && float(GetClientHealth(victim)) <= damage )
                {
                    bWitchGotKill = true;
                }
            }
        }
    }
    return Plugin_Continue;
}


/* --------------------------------------
 *            Tank (mainly)
 * -------------------------------------- */

public OnClientDisconnect_Post(client)
{
    if ( !bTankSpawned || client != iTankClient )
    {
        return;
    }
    
    // Use a delayed timer due to bugs where the tank passes to another player
    CreateTimer(TANKCHECKTIME, Timer_CheckTank, client);
}


public Action:L4D_OnSpawnTank(const Float:vector[3], const Float:qangle[3])
{
    bTankSpawned = true;
    if ( GetConVarBool(hDoorBlockTank) )
    {
        BlockDoor();
    }
    return Plugin_Continue;
}

public Event_TankSpawned(Handle:event, const String:name[], bool:dontBroadcast)
{
    bTankSpawned = true;
    new client = GetClientOfUserId(GetEventInt(event, "userid"));
    iTankClient = client;

    if ( GetConVarBool(hFreezeDistTank) )
    {
        L4D_SetVersusMaxCompletionScore(0);
    }
}

public Event_PlayerKilled ( Handle:event, const String:name[], bool:dontBroadcast )
{
    new victim = GetClientOfUserId( GetEventInt(event, "userid") );
    if ( !victim || !IsValidEdict(victim) || !IsClientAndInGame(victim) ) { return; }

    // for checking on DT3, during event, players get a 'lasted time'
    if ( bDT3 && bDT3Started )
    {
        if ( GetClientTeam(victim) == TEAM_SURVIVOR )
        {
            // survivor died, remember what time it was
            fDT3SurvivorLasted[victim] = GetTickedTime() - fDT3StartTime;
        }
    }

    // Tank bonus:
    // No tank in play; no damage to record
    if (    !bTankSpawned ||
            victim != iTankClient ||
            GetClientTeam(victim) != TEAM_INFECTED ||
            GetEntProp(victim, Prop_Send, "m_zombieClass" ) != ZC_TANK
    ) {
        return;
    }

    // check if the tank was really killed
    CreateTimer(TANKCHECKTIME, Timer_CheckTank, victim);                        // Use a delayed timer due to bugs where the tank passes to another player
}

public Action:Timer_CheckTank(Handle:timer, any:oldtankclient)
{
    // Tank passed
    if ( iTankClient != oldtankclient ) { return; }

    new tankclient = FindTankClient();
    if ( tankclient && tankclient != oldtankclient )
    {
        // Tank not dead yet.
        iTankClient = tankclient;
        return;
    }

    // killed tank, full bonus awarded
    new tmpBonus = 0;
    tmpBonus = GetConVarInt(hBonusTank);
    
    PBONUS_AddRoundBonus( tmpBonus );
    iBonusShow[iTeamPlaying] += tmpBonus;

    new Handle: pack;
    decl String: buffer[MAX_MESSAGE_LENGTH];
    Format(buffer, sizeof(buffer), "\x01[calamity] Team %s gets\x04 %d \x01bonus points for killing tank.", ((iTeamPlaying)?"B":"A"), tmpBonus);
    CreateDataTimer(DISPLAYDELAYTIME, delayedMessage, pack);
    WritePackString(pack, buffer);

    // check if rushprotection is currently enabled
    if ( !bRushProtection || !GetConVarBool(hFreezeDistRush) )
    {
        L4D_SetVersusMaxCompletionScore(iDistance);
    }
    if ( !bRushProtection || !GetConVarBool(hDoorBlockRush) )
    {
        UnBlockDoor();
    }

    bTankSpawned = false;
}

stock CheckTankWipeBonus ()
{
    // find tank player.. do nothing if not found
    new tankClient = GetTankClient();
    if ( !tankClient ) { return false; }
    new tmpBonus = 0;
    
    // if it's dying, it counts as a full kill
    if ( IsTankDying(tankClient) )
    {
        tmpBonus = GetConVarInt(hBonusTank);

        if ( tmpBonus )
        {
            PBONUS_AddRoundBonus( tmpBonus );
            iBonusShow[iTeamPlaying] += tmpBonus;
            
            new Handle: pack;
            decl String: buffer[MAX_MESSAGE_LENGTH];
            Format(buffer, sizeof(buffer), "\x01[calamity] Team %s gets\x04 %d \x01bonus points for killing tank.", ((iTeamPlaying)?"B":"A"), tmpBonus);
            CreateDataTimer(DISPLAYDELAYTIME, delayedMessage, pack);
            WritePackString(pack, buffer);
        }
    }
    else if ( GetConVarBool(hBonusTankPercent) )
    {
        // if not, give percentage of bonus acc. to health
        // else, check convar and give according percentage
        new Float: fullHealth = TANK_HEALTH_FACTOR * GetConVarFloat(hCvarTankHealth);             // gotta multiply by factor for VS
        new Float: tankHealth = float(GetClientHealth(tankClient));
        new Float: factor = (fullHealth > 0.0) ? ((fullHealth - tankHealth) / fullHealth) : 0.0;
        tmpBonus = RoundFloat(factor * GetConVarFloat(hBonusTank));

        if ( tmpBonus < 0 ) { tmpBonus = 0; }
        //PrintToChatAll("[test] tank (%d %N) health %.0f - %.0f (factor %.2f) = bonus %d.", tankClient, tankClient, fullHealth, tankHealth, factor, tmpBonus);

        if ( tmpBonus )
        {
            PBONUS_AddRoundBonus( tmpBonus );
            iBonusShow[iTeamPlaying] += tmpBonus;
            
            new Handle: pack;
            decl String: buffer[MAX_MESSAGE_LENGTH];
            Format(buffer, sizeof(buffer), "\x01[calamity] Team %s gets\x04 %d \x01bonus points for hurting tank (\x03%.0f%%\x01).", ((iTeamPlaying)?"B":"A"), tmpBonus, (factor * 100.0));
            CreateDataTimer(DISPLAYDELAYTIME, delayedMessage, pack);
            WritePackString(pack, buffer);
        }
    }
    bTankSpawned = false;
    bCheckWipeTankDone = true;
    
    return tmpBonus;
}

GetTankClient ()
{
    if ( !bTankSpawned ) { return 0; }
    new tankclient = iTankClient;

    // If tank somehow is no longer in the game (kicked, hence events didn't fire)
    if ( !IsClientAndInGame(tankclient) )
    {
        // find the tank client
        tankclient = FindTankClient();
        if ( !tankclient ) { return 0; }
        iTankClient = tankclient;
    }
    return tankclient;
}

FindTankClient ()
{
    for ( new client = 1; client <= MaxClients; client++ )
    {
        if ( !IsClientAndInGame(client) ) { continue; }
        if ( GetClientTeam(client) != TEAM_INFECTED || !IsPlayerAlive(client) || GetEntProp(client, Prop_Send, "m_zombieClass") != ZC_TANK )
        {
            continue;
        }
        return client;
    }
    return 0;
}


/* --------------------------------------
 *         shared functions
 * -------------------------------------- */

bool:IsClientAndInGame(index)
{
    if ( index > 0 && index <= MaxClients )
    {
        return IsClientInGame(index);
    }
    return false;
}

stock bool:IsSurvivor(client) { return (IsClientAndInGame(client)) ? (GetClientTeam(client) == TEAM_SURVIVOR) : false; }
stock bool:IsIncapped(client) { return bool:GetEntProp(client, Prop_Send, "m_isIncapacitated", 1); }
stock bool:IsHanging(client) { return bool:GetEntProp(client, Prop_Send, "m_isHangingFromLedge"); }

stock GetUprightSurvivors ()
{
    new iAliveCount;
    new iSurvivorCount;
    
    for ( new i = 1; i <= MaxClients && iSurvivorCount < MAX_SURVIVORS; i++ )
    {
        if ( !IsSurvivor(i) ) { continue; }
        iSurvivorCount++;
        
        if ( !IsPlayerAlive(i) || IsIncapped(i) || IsHanging(i) ) { continue; }
        iAliveCount++;
    }
    
    return iAliveCount;
}

stock bool:IsSurvivorRushing ()
{
    new iAliveCount;
    new iUprightCount;
    new iSurvivorCount;
    
    for ( new i = 1; i <= MaxClients && iSurvivorCount < MAX_SURVIVORS; i++ )
    {
        if ( !IsSurvivor(i) ) { continue; }
        iSurvivorCount++;
        
        if ( !IsPlayerAlive(i) ) { continue; }
        iAliveCount++;
        
        if ( !IsIncapped(i) && !IsHanging(i) )
        {
            iUprightCount++;
        }
    }

    new maxUp = GetConVarInt(hRushThreshold);

    return bool:( iUprightCount <= maxUp && iAliveCount > maxUp );
}

stock GetCurrentSurvivorTeam ()
{
    // returns wether team 0 or 1 is currently running survivor
    return ( iRoundNumber < 1 && bTeamAFirst || iRoundNumber > 0 && !bTeamAFirst ) ? TEAM_A : TEAM_B;
}

stock bool: IsWitch ( iEntity )
{
    if ( iEntity > 0 && IsValidEntity(iEntity) && IsValidEdict(iEntity) )
    {
        decl String:strClassName[64];
        GetEdictClassname(iEntity, strClassName, sizeof(strClassName));
        return StrEqual(strClassName, "witch");
    }
    return false;
}

bool:IsTankDying(client)
{
    if (!client)
    {
        client = GetTankClient();
        if ( !client ) { return false; }
    }
    return bool:GetEntData( client, iOffset_Incapacitated );
}

stock ClearHurtWitch ()
{
    for ( new i = 1; i <= MaxClients; i++ )
    {
        bHurtWitch[i] = false;
    }
}

stock GetHurtWitch ()
{
    new iHurtWitch = 0;
    for ( new i = 1; i <= MaxClients; i++ )
    {
        if ( bHurtWitch[i] ) { iHurtWitch++; }
    }
    return iHurtWitch;
}

stock GetMapMaxScore ()
{
    return L4D_GetVersusMaxCompletionScore();
}
