import tables, options, asyncdispatch, json, times
import dimscord
import db_postgres as pg
from marshal import to
from strutils import toUpperAscii, parseInt, startsWith
from os import paramStr, paramCount

type
    HagridConfig* = object
        ## Type rassemblant les variables nécessaires au fonctionnement du bot
        db*: DbConn ## connexion à la BDD
        checkHouseCooldown*: seq[string] ## cooldown pour checkUserHouseRole
        cooldownCommands*: Table[string, seq[string]]
        otherCooldowns*: Table[string, seq[string]]
        lang*: Table[string, Table[string, string]] ## table des traductions [message, [langue, traduction]]
        usedPrefix*: string ## prefix utilisé par le bot actuellement
        ##
        # Données du JSON
        token*: string ## token du bot
        prefix: string ## prefix de la version release
        devPrefix: string ## prefix de la version dev
        guildId*: string ## ID du serveur principal (bot ne réagit qu'aux évènements de ce serveur)
        pgIpAdress*: string ## adresse IP PG distant
        pgUser*: string ## nom utilisateur PG
        pgPass*: string ## mdp PG
        pgDbName*: string ## nom BDD
        ##
        introMessageId*: string ## ID du message du firewall
        introReactionRoles*: seq[string] ## ID des rôles à donner pour accéder au serveur
        ticketMessageId*: string ## ID du message où il faut réagir pour ouvrir un ticket
        ticketAllowedRoles*: seq[string] ## ID des rôles à autoriser dans le salon ticket
        ticketCategoryId*: string ## ID de la catégorie parente du ticket
        ticketEmojiId*: string ## ID de la réaction du système de tickets
        premiumRoleId*: string ## ID du rôle Premium
        trafficChannelId*: string ## ID du salon des arrivées/départs
        enServiceRoleId*: string ## ID du rôle "En Service"
        enServiceMessageId*: string ## ID du message où réagir
        enServiceReactionId*: string ## ID de la réaction à cliquer
        enServiceAllowedRoles*: seq[string] ## ID des rôles autorisés à avoir le rôle

    House* = object
        ## Représente une maison dans la BDD
        points*: Natural ## 0 par défaut, utiliser getHouse("nom", true) pour fetch la BDD
        dbId*: range[1..4] ## ID dans la BDD
        name*: string ## nom
        roleId*: string ## ID du rôle de la maison sur le serv principal

    DbUser* = object
        ## Représente les données d'un utilisateur
        id*: string ## ID de l'utilisateur
        lang*: string ## code du langage ("fr" si utilisateur pas dans table `alluser`)
        house*: Option[House] ## maison du joueur
        datePremium*: Time ## date jusqu'à laquelle l'utilisateur est premium (timestamp 0 si pas premium)
        member*: Option[Member] ## object Membre correspondant si utilisateur sur le serveur support

proc isDevVersion*(): bool =
    ## Retourne true si "devVersion" est passé en argument
    return paramCount() > 0 and paramStr(1) == "devVersion" # paramStr(0) = URL du programme

proc initHgConf(): HagridConfig =
    ## Initialise la configuration, les traductions et la connexion à la BDD
    var d = readFile("res/config.json").to[:HagridConfig]

    for field, value in parseJson(readFile("res/lang.json")).fields.pairs:
        d.lang[field] = initTable[string, string]()
        for lang, text in value.fields:
            d.lang[field][lang] = text.str
    
    d.usedPrefix = if isDevVersion(): d.devPrefix else: d.prefix

    d.db = pg.open((if isDevVersion(): d.pgIpAdress else: "localhost"), d.pgUser, d.pgPass, d.pgDbName)
    return d

var
    hgConf* = initHgConf() ## HagridConfig du bot
    discord* = newDiscordClient(hgConf.token) ## Client du bot

proc timestampToTime(time: var string): Time=
    ## Prends un timestamp de la BDD et retourne un objet Time
    if time == "":
        time = "0"
    (time.parseInt / 1000).int.fromUnix


## Les données constantes des maisons (nom, dbId, roleId)
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
    ## Renvoie les données de la maison demandée.
    ## Pour obtenir les points, mettre queryDb à true
    var name = name.toUpperAscii
    if not DefinedHouses.hasKey(name):
        return none(House)
    var val = DefinedHouses[name]
    if queryDb:
        val.points = hgConf.db.getRow(sql"SELECT points FROM maisons WHERE nom = ?", name)[0].parseInt
    return some(val)

proc getShard0*(): Shard=
    ## Retourne le Shard 0 (pour utiliser le cache notamment)
    return discord.shards[0]

proc getMember*(memberId: string): Option[Member]=
    ## Retourne un potentiel objet Member associé à l'ID d'un utilisateur
    let guildsCache = getShard0().cache.guilds
    if hgConf.guildId in guildsCache and memberId in guildsCache[hgConf.guildId].members:
        result = some(guildsCache[hgConf.guildId].members[memberId])
    try:
        result = some(waitFor discord.api.getGuildMember(hgConf.guildId, memberId))
    except:
        result = none(Member)

proc getUserFromDb*(userId: string, queryHouse = false): DbUser=
    ## Fetch un utilisateur de la BDD
    var val = hgConf.db.getRow(sql"""SELECT users.maison, users."datePremium", alluser.lang FROM users INNER JOIN alluser ON users.id = alluser.id WHERE users.id = ?""", userId)
    if val[2] == "": # si pas de langage (premier message)
        val[2] = "fr"
    return DbUser(
        id: userId,
        house: getHouse(val[0], queryHouse),
        member: getMember(userId),
        lang: val[2],
        datePremium: timestampToTime(val[1])
    )

proc getLang*(search: string, lang: string): string=
    ## Renvoie le texte demandé dans la langue donnée
    var lang = lang # la redéclarer en var pour pouvoir la modifier
    if lang.len != 2: # si ce n'est pas un code ("fr", "en", "es") c'est l'ID
        lang = getUserFromDb(lang).lang
    if not hgConf.lang.hasKey(search) or not hgConf.lang[search].hasKey(lang):
        return "error lang" # si la recherche n'aboutie pas
    return hgConf.lang[search][lang]

proc getLang*(userDb: DbUser, search: string): string=
    ## Renvoie le texte demandé dans la langue de l'utilisateur
    getLang(search, userDb.lang)

proc checkUserHouseRole*(member: Member)=
    ## Vérifie que l'utilisateur n'a que le rôle de sa maison (et lui ajoute)
    let userDb = getUserFromDb(member.user.id)
    if userDb.house.isSome: # rôle maison
        for house in DefinedHouses.values:
            if house.dbId == userDb.house.get.dbId and house.roleId notin member.roles: # sa maison mais ne possède pas le rôle
                discard discord.api.addGuildMemberRole(hgConf.guildId, member.user.id, house.roleId)
            elif house.dbId != userDb.house.get.dbId and house.roleId in member.roles: # pas sa maison et possède le rôle
                discard discord.api.removeGuildMemberRole(hgConf.guildId, member.user.id, house.roleId)
        
        if userDb.datePremium != 0.fromUnix: # premium
            if userDb.datePremium <= getTime(): # check si premium ou non
                hgConf.db.exec(sql"""UPDATE users SET "datePremium" = '' WHERE id = ?; COMMIT;""", userDb.id)
                if hgConf.premiumRoleId in member.roles: # Retire le rôle premium si il l'a
                    discard discord.api.removeGuildMemberRole(hgConf.guildId, member.user.id, hgConf.premiumRoleId)
            else:
                if hgConf.premiumRoleId notin member.roles: # Ajoute le rôle si l'utilisateur ne l'a pas
                    discard discord.api.addGuildMemberRole(hgConf.guildId, member.user.id, hgConf.premiumRoleId)

proc mentionUser*(user: User): string=
    ## Retourne la mention de l'utilisateur <@id>
    "<@" & user.id & ">"

proc animatedAvatarUrl*(user: User): string=
    ## Retourne l'avatar de la personne, animé si disponible sinon avatarUrl()
    if user.avatar.get("").startsWith("a_"): # hash précédé de "a_" si pp animée
        result = user.avatarUrl("gif")
    else:
        result = user.avatarUrl()

const CommandsAliases: Table[string, seq[string]] = {
    "toggleservice": @["ts"]
}.toTable

proc getCommandName*(cmd: string): string=
    if CommandsAliases.hasKey(cmd): return cmd
    for command, aliases in CommandsAliases.pairs:
        if cmd in aliases: return command
    return ""

proc putInCooldown*(userId, cmd: string, waitMs: int) {.async.}=
    if hgConf.cooldownCommands.hasKey(userId):
        hgConf.cooldownCommands[userId].add(cmd)
    else:
        hgConf.cooldownCommands[userId] = @[cmd]
    await sleepAsync(waitMs)
    hgConf.cooldownCommands[userId].delete(hgConf.cooldownCommands[userId].find(cmd))
    if hgConf.cooldownCommands[userId].len == 0:
        hgConf.cooldownCommands.del(userId)