import tables, options, asyncdispatch, json, times
import dimscord
import db_postgres as pg
from marshal import to
from strutils import toUpperAscii, parseInt, startsWith

type
    HagridConfig* = object
        db*: DbConn
        checkHouseCooldown*: seq[string]
        lang: Table[string, Table[string, string]]
        ### dans le JSON
        token*: string
        prefix*: string
        devPrefix*: string
        guildId*: string
        # Posgtres IDs
        pgIpAdress*: string
        pgUser*: string
        pgPass*: string
        pgDbName*: string
        introReactionId*: string
        introReactionRoles*: seq[string]
        ticketReactionId*: string
        ticketAllowedRoles*: seq[string]
        ticketCategoryId*: string
        ticketEmojiId*: string
        premiumRoleId*: string
        trafficChannelId*: string

    House* = object
        points*: int
        dbId*: range[1..4]
        name*: string
        roleId*: string

    DbUser* = object
        id*: string
        lang*: string
        house*: Option[House]
        datePremium*: Time
        member*: Option[Member]

proc isDevVersion*(): bool =
    return true #not defined linux

proc initHgConf(): HagridConfig =
    var d = readFile("res/config.json").to[:HagridConfig]

    for field, value in parseJson(readFile("res/lang.json")).fields.pairs:
        d.lang[field] = initTable[string, string]()
        for lang, text in value.fields:
            d.lang[field][lang] = text.str
    d.db = pg.open((if isDevVersion(): d.pgIpAdress else: "localhost"), d.pgUser, d.pgPass, d.pgDbName)
    return d

var
    hgConf* = initHgConf()
    discord* = newDiscordClient(hgConf.token)

proc timestampToTime(time: var string): Time=
    if time == "":
        time = "0"
    (time.parseInt / 1000).int.fromUnix

const DefinedHouses: Table[string, House] = {
    "GRYFFONDOR": House(
        dbId: 1,
        name: "Gryffondor",
        roleId: "796774549232287754"
    ),
    "POUFSOUFFLE": House(
        roleId: "796775145317859373",
        name: "Poufsouffle",
        dbId: 3,
    ),
    "SERPENTARD": House(
        roleID: "796774926383972383",
        name: "Serpentard",
        dbId: 2,
    ),
    "SERDAIGLE": House(
        roleID: "796775403707826227",
        name: "Serdaigle",
        dbId: 4,
    ),
}.toTable

proc getHouse*(name: string, queryDb = false): Option[House]=
    var name = name.toUpperAscii
    if not DefinedHouses.hasKey(name):
        return none(House)
    var val = DefinedHouses[name]
    if queryDb:
        val.points = hgConf.db.getRow(sql"SELECT points FROM maisons WHERE nom = ?", name)[0].parseInt
    return some(val)

proc getShard0*(): Shard=
    return discord.shards[0]

proc getMember*(memberId: string): Option[Member]=
    let guildsCache = getShard0().cache.guilds
    if hgConf.guildId in guildsCache and memberId in guildsCache[hgConf.guildId].members:
        result = some(guildsCache[hgConf.guildId].members[memberId])
    try:
        result = some(waitFor discord.api.getGuildMember(hgConf.guildId, memberId))
    except:
        result = none(Member)

proc getUserFromDb*(userId: string, queryHouse = false): DbUser=
    var val = hgConf.db.getRow(sql"""SELECT users.maison, users."datePremium", alluser.lang FROM users INNER JOIN alluser ON users.id = alluser.id WHERE users.id = ?""", userId)
    if val[2] == "":
        val[2] = "fr"
    return DbUser(
        id: userId,
        house: getHouse(val[0], queryHouse),
        member: getMember(userId),
        lang: val[2],
        datePremium: timestampToTime(val[1])
    )

proc getLang*(search: string, lang: string): string=
    var lang = lang
    if lang.len != 2:
        lang = getUserFromDb(lang).lang
    if not hgConf.lang.hasKey(search) or not hgConf.lang[search].hasKey(lang):
        return "error lang"
    return hgConf.lang[search][lang]

proc getLang*(userDb: DbUser, search: string): string=
    return getLang(search, userDb.lang)

proc checkUserHouseRole*(member: Member)=
    let userDb = getUserFromDb(member.user.id)
    if userDb.house.isSome:
        for house in DefinedHouses.values:
            if house.dbId == userDb.house.get.dbId and house.roleId notin member.roles: # sa maison mais ne possède pas le rôle
                discard discord.api.addGuildMemberRole(hgConf.guildId, member.user.id, house.roleId)
            elif house.dbId != userDb.house.get.dbId and house.roleId in member.roles: # pas sa maison et possède le rôle
                discard discord.api.removeGuildMemberRole(hgConf.guildId, member.user.id, house.roleId)
        
        if userDb.datePremium != 0.fromUnix:
            if userDb.datePremium <= getTime():
                hgConf.db.exec(sql"""UPDATE users SET "datePremium" = '' WHERE id = ?""", userDb.id)
                if hgConf.premiumRoleId in member.roles:
                    discard discord.api.removeGuildMemberRole(hgConf.guildId, member.user.id, hgConf.premiumRoleId)
            else:
                if hgConf.premiumRoleId notin member.roles:
                    discard discord.api.addGuildMemberRole(hgConf.guildId, member.user.id, hgConf.premiumRoleId)

proc mentionUser*(user: User): string=
    "<@" & user.id & ">"

proc animatedAvatarUrl*(user: User): string=
    if user.avatar.get("").startsWith("a_"):
        result = user.avatarUrl("gif")
    else:
        result = user.avatarUrl()