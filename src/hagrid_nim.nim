import dimscord, asyncdispatch, options, strutils, tables
from times import now, `$`
from sequtils import concat, items, any
from sugar import `=>`
import ./types

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  echo "Ready as: " & $r.user & " at " & $now()

  # discard discord.api.addMessageReaction("740846065325965412", "740847220273709076", hgConf.ticketEmojiId)

proc messageCreate(s: Shard, m: Message) {.event(discord).} =
  if m.guild_id.get("") != hgConf.guildId or m.author.bot or m.member.isNone:
    return

  m.member.get.user = m.author

  if m.author.id notin hgConf.checkHouseCooldown and not isDevVersion():
    proc addAndDelete() {.async.}=
      checkUserHouseRole(m.member.get)
      hgConf.checkHouseCooldown.add(m.author.id)
      await sleepAsync(20_000) # attends 20 secondes et le supprime
      hgConf.checkHouseCooldown.delete(hgConf.checkHouseCooldown.find(m.author.id))
    discard addAndDelete()

  if not m.content.startsWith(hgConf.usedPrefix): return

  let
    userDb = getUserFromDb(m.author.id)
    args = m.content.substr(hgConf.usedPrefix.len).split(" ")
    command = getCommandName(args[0])

  if command == "":
    discard discord.api.sendMessage(m.channel_id, userDb.getLang("unknownCommand").replace("{{cmd}}", args[0]))
    return

  if hgConf.cooldownCommands.hasKey(m.author.id) and command in hgConf.cooldownCommands[m.author.id]:
    discard discord.api.sendMessage(m.channel_id, userDb.getLang("inCooldown"))
    return

  try:
    case args[0]:
    of "toggleservice", "ts":
      if hgConf.enServiceAllowedRoles.any(r => r in m.member.get.roles):
        if hgConf.enServiceRoleId in m.member.get.roles:
          await discord.api.removeGuildMemberRole(hgConf.guildId, m.author.id, hgConf.enServiceRoleId)
          discard discord.api.sendMessage(m.channel_id, userDb.getLang("enServiceWithdrawed"))
        else:
          await discord.api.addGuildMemberRole(hgConf.guildId, m.author.id, hgConf.enServiceRoleId)
          discard discord.api.sendMessage(m.channel_id, userDb.getLang("enServiceGave"))
      else:
        discard discord.api.sendMessage(m.channel_id, userDb.getLang("enServiceNotAllowed"))
    of "rereact":
      # TODO: commande pour reréagir à tous les messages nécessaires
      discard
  except:
    echo repr(getCurrentExceptionMsg())
    discard discord.api.sendMessage(m.channel_id, userDb.getLang("errorOccured"))

  discard putInCooldown(userDb.id, command, 5_000)

proc messageReactionAdd(s: Shard, m: Message,
  u: User, e: Emoji, exists: bool) {.event(discord).} =
  if m.guild_id.get("") != hgConf.guildId or u.bot or m.member.isNone:
    return

  let u = await discord.api.getUser(u.id)

  if m.id == hgConf.introMessageId: # firewall
    if not hgConf.otherCooldowns.hasKey("intro"):
      hgConf.otherCooldowns["intro"] = @[]
    if u.id in hgConf.otherCooldowns["intro"]:
      return
    hgConf.otherCooldowns["intro"].add(u.id)
  
    defer: hgConf.otherCooldowns["intro"].delete(hgConf.otherCooldowns["intro"].find(u.id))
    defer: await sleepAsync(20_000)

    echo "Reaction firewall de: " & $u
    for r in hgConf.introReactionRoles:
      if r notin m.member.get.roles:
        echo "\tAjout du role: " & r
        discard discord.api.addGuildMemberRole(hgConf.guildId, u.id, r)
        await sleepAsync(1_000)
  elif m.id == hgConf.ticketMessageId and e.id.get("") == hgConf.ticketEmojiId.split(":")[1]: # tickets
    defer: await discord.api.addMessageReaction(m.channel_id, m.id, hgConf.ticketEmojiId)
    defer: await discord.api.deleteAllMessageReactions(m.channel_id, m.id)
    let userDb = getUserFromDb(u.id)

    for channel in getShard0().cache.guilds[hgConf.guildId].channels.values:
      if channel.topic.get("").startsWith(u.id):
        discard discord.api.sendMessage(channel.id,
          u.mentionUser & " " & getLang("ticketChannelAlreadyExists", userDb.lang))
        return
    
    let permsSet = {permViewChannel, permSendMessages, permAttachFiles, permReadMessageHistory, permUseExternalEmojis, permAddReactions}
    var perms: seq[Overwrite] = @[]

    for role in hgConf.ticketAllowedRoles.items:
      perms.add(Overwrite(id: role, allow: permsSet, kind: "role"))

    try:
      let createdChannel = await discord.api.createGuildChannel(
        hgConf.guildId,
        name = u.username, kind = ord(ctGuildText), topic = some u.id,
        parent_id = some hgConf.ticketCategoryId,
        permission_overwrites = some concat(
          @[Overwrite(id: u.id, allow: permsSet, kind: "member"),
            Overwrite(id: hgConf.guildId, deny: {permViewChannel}, kind: "role")],
          perms)
      )
      echo "Creation de ticket pour: " & $u
      await sleepAsync(3_000)
      discard discord.api.sendMessage(createdChannel.id,
        content=getLang("afterTicketMention", "fr").replace("{{uid}}", u.id),
        embed=some Embed(
          author: some EmbedAuthor(name: some u.username, icon_url: some u.animatedAvatarUrl()),
          description: some userDb.getLang("ticketMessage")))
    except:
      let
        e = getCurrentException()
        msg = getCurrentExceptionMsg()
      echo "Error creating ticket channel: " & repr(e) & " with message \"" & msg & "\""
      let sended = await discord.api.sendMessage(m.channel_id, userDb.getLang("ticketError"))
      await sleepAsync(10_000)
      try:
        discard discord.api.deleteMessage(m.channelId, sended.id)
      except: discard
  elif m.channel_id == hgConf.assignableRolesChannelId: # reaction roles
    var roleId = hgConf.assignableRoles.getKeyByValue($e)
    if roleId.isNone:
      echo "Mauvais emoji dans le salon des roles assignables:"
      echo "\t" & $u & " a reagi avec: \"" & e.id.get("") & "\""
      return

    let userDb = getUserFromDb(u.id)

    if not getShard0().cache.guilds[hgConf.guildId].roles.hasKey(roleId.get):
      echo "Le role avec l'ID \"" & roleId.get & "\" est introuvable"
      discard discord.api.sendMessage(getDMChannel(u.id).id,
        userDb.getLang("roleError").replace("{id}", roleId.get))
      return
    discard discord.api.addGuildMemberRole(hgConf.guildId, u.id, roleId.get)

proc messageReactionRemove(s: Shard, m: Message,
  u: User, r: Reaction, exists: bool) {.event(discord).} =
  if m.guild_id.get("") != hgConf.guildId or u.bot:
    return

  let u = await discord.api.getUser(u.id)
  if m.channel_id == hgConf.assignableRolesChannelId:
    var roleId = hgConf.assignableRoles.getKeyByValue($r.emoji)
    if roleId.isNone:
      return

    discard discord.api.removeGuildMemberRole(hgConf.guildId, u.id, roleId.get)

proc guildMemberAdd(s: Shard, g: Guild, m: Member) {.event(discord).} =
  if g.id != hgConf.guildId or isDevVersion(): return

  let lang = getUserFromDb(m.user.id).lang
  echo "Un membre a rejoint: " & $m.user
  discard discord.api.sendMessage(
    hgConf.trafficChannelId,
    getLang("welcomeMessage", lang)
      .multiReplace(("{{mention}}", m.user.mentionUser), ("{{count}}", $g.member_count.get(-1)))
  )

proc guildMemberRemove(s: Shard, g: Guild, m: Member) {.event(discord).} =
  if g.id != hgConf.guildId or isDevVersion(): return

  echo "Un membre a quitte: " & $m.user
  discard discord.api.sendMessage(
    hgConf.trafficChannelId,
    getLang("byeMessage", "fr")
      .replace("{{username}}", m.user.mentionUser & " `(" & $m.user & ")`")
  )

# https://nim-lang.org/docs/asyncdispatch.html

when isMainModule:
  waitFor discord.startSession(
    gateway_intents = {giGuildMessages, giGuilds, giGuildMembers, giGuildMessageReactions},
    guild_subscriptions = false
  )
