import dimscord, asyncdispatch, options, strutils, tables
from times import now, `$`
from sequtils import concat, items, any
import ./types

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  echo "Ready as: " & $r.user & " at " & $now()

  # discard discord.api.addMessageReaction("740846065325965412", "740847220273709076", hgConf.ticketEmojiId)

proc messageCreate(s: Shard, m: Message) {.event(discord).} =
  if m.guild_id.get("") != hgConf.guildId or m.author.bot or m.member.isNone:
    return

  m.member.get.user = m.author

  if m.author.id notin hgConf.checkHouseCooldown:
    proc addAndDelete() {.async.}=
      checkUserHouseRole(m.member.get)
      hgConf.checkHouseCooldown.add(m.author.id)
      await sleepAsync(5_000) # attends 20 secondes et le supprime
      hgConf.checkHouseCooldown.delete(hgConf.checkHouseCooldown.find(m.author.id))
    discard addAndDelete()

  if not m.content.startsWith(hgConf.usedPrefix): return
  
  let
    userDb = getUserFromDb(m.author.id)
    args = m.content.substr(hgConf.usedPrefix.len).split(" ")

  try:
    case args[0]:
    of "toggleservice", "ts":
      if hgConf.enServiceAllowedRoles.any(proc (r: string): bool = r in m.member.get.roles):
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
    else:
      discard discord.api.sendMessage(m.channel_id,
        userDb.getLang("unknownCommand").replace("{{cmd}}", args[0]))
  except:
    echo repr(getCurrentExceptionMsg())
    discard discord.api.sendMessage(m.channel_id, userDb.getLang("errorOccured"))

proc messageReactionAdd(s: Shard, m: Message,
  u: User, e: Emoji, exists: bool) {.event(discord).} =
  if m.guild_id.get("") != hgConf.guildId or u.bot or m.member.isNone:
    return

  let u = await discord.api.getUser(u.id)

  if m.id == hgConf.introMessageId:
    for r in hgConf.introReactionRoles:
      if r notin m.member.get.roles:
        discard discord.api.addGuildMemberRole(hgConf.guildId, u.id, r)
  elif m.id == hgConf.ticketMessageId and e.id.get("") == hgConf.ticketEmojiId.split(":")[1]:
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
      discard discord.api.sendMessage(createdChannel.id,
        content=getLang("afterTicketMention", "fr").replace("{{uid}}", u.id),
        embed=some Embed(
          author: some EmbedAuthor(name: some $u, icon_url: some u.animatedAvatarUrl()),
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

proc guildMemberAdd(s: Shard, g: Guild, m: Member) {.event(discord).} =
  if g.id != hgConf.guildId: return

  let lang = getUserFromDb(m.user.id).lang
  discard await discord.api.sendMessage(
    hgConf.trafficChannelId,
    getLang("welcomeMessage", lang)
      .multiReplace(("{{mention}}", m.user.mentionUser), ("{{count}}", $g.member_count.get(-1)))
  )

proc guildMemberRemove(s: Shard, g: Guild, m: Member) {.event(discord).} =
  if g.id != hgConf.guildId: return

  discard await discord.api.sendMessage(
    hgConf.trafficChannelId,
    getLang("byeMessage", "fr")
      .replace("{{username}}", m.user.mentionUser & " `(" & m.user.username & ")`")
  )

# https://nim-lang.org/docs/asyncdispatch.html

when isMainModule:
  waitFor discord.startSession(
    gateway_intents = {giGuildMessages, giGuilds, giGuildMembers, giGuildMessageReactions}
  )
