// Released under the terms of GPLv3 or at your option any later version.
// No warranties.
// Copyright 2009 Enrico Tassi <gares@fettunta.org>

errordomain Exit { ABORT }

// a simple class to pass data from the child process to the
// notofier
class Event {
	public string message;
	public bool enter_error_mode;

	public static Event error(string account, string host) {
		var e = new Event();
		e.message = "An error occurred, click on the icon for more details";
		e.enter_error_mode = true;
		return e;
	}

	public static Event stats(
		string account,string host,int new_mails,int del_mails) 
	{
		string preamble = "Synchronize with %s:\n".printf(account);
		var e = new Event();
		e.enter_error_mode = false;
		if (new_mails > 0 && del_mails > 0) {
			e.message = "%s%d new messages\n%d deleted messages".
				printf(preamble,new_mails,del_mails);
		} else if (new_mails > 0) {
			e.message = "%s%d new messages".printf(preamble,new_mails);
		} else {
			e.message = "%s%d deleted messages".printf(preamble,del_mails);
		}
		return e;
	}
}

static const string SMD_LOOP = "/bin/smd-loop";
static const string SMD_APPLET_UI = "/share/smd-applet/smd-applet.ui";

// the main class containing all the data smd-applet will use
class smdApplet {

	// =================== the constants ===============================

	// gconf keys
	static const string key_icon    = "/apps/smd-applet/icon_only_on_errors";
	static const string key_newmail = "/apps/smd-applet/notify_new_mail";

	// paths, set by main() to something that depends on the 
	// installation path
	public static string smd_loop_cmd = null;
	public static string smd_applet_ui = null;

	// =================== the data =====================================

	// The builder
	Gtk.Builder builder = null;

	// main widgets
	Gtk.Menu menu = null;
	Gtk.StatusIcon si = null;
	Gtk.Window win = null;
	Gtk.Window err_win = null;

	// the gconf client handler
	GConf.Client gconf = null;

	// the thread to manage the child smd-loop instance
	weak GLib.Thread thread = null;
	
	// communication structure between the child process (managed by a thread
	// and the notifier timeout handler).
	GLib.Mutex events_lock = null;
	List<Event> events = null; 

	// if the program is stuck
	bool error_mode;
	GLib.HashTable<Gtk.Widget,string> command_hash = null;

	// =================== the code =====================================

	// initialize data structures and build gtk+ widgets
	smdApplet() {
		// load the ui file
		builder = new Gtk.Builder ();
		try { builder.add_from_file (smd_applet_ui); } 
		catch (GLib.Error e) { 
			stderr.printf("%s\n",e.message); 
			throw new Exit.ABORT("Unable to load the ui file");
		}
	
		// events queue and mutex
		events = new List<Event>();
		events_lock = new GLib.Mutex();

		// connect to gconf
		gconf = GConf.Client.get_default();

		// load widgets and attach callbacks
		win = builder.get_object("wPrefs") as Gtk.Window;
		err_win = builder.get_object("wError") as Gtk.Window;
		var close = builder.get_object("bClose") as Gtk.Button;
		close.clicked += (b) =>  { win.hide(); };
		var bicon = builder.get_object("cbIcon") as Gtk.CheckButton;
		bicon.set_active( gconf.get_bool(key_icon));
		bicon.toggled += (b) => {
			try { gconf.set_bool(key_icon,b.active); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
		};
		var bnotify = builder.get_object("cbNotify") as Gtk.CheckButton;
		bnotify.set_active( gconf.get_bool(key_newmail));
		bnotify.toggled += (b) => {
			try { gconf.set_bool(key_newmail,b.active); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
		};
		var bc = builder.get_object("bClose") as Gtk.Button;
		bc.clicked += (b) => {
			err_win.hide();	
			error_mode = false;
			si.set_from_icon_name("gtk-info");
			si.set_blinking(false);
			// XXX do something else?
		};
		win.delete_event += win.hide_on_delete;
		err_win.delete_event += err_win.hide_on_delete;

		// menu popped up when the user clicks on the notification area
        menu = builder.get_object ("mMain") as Gtk.Menu;
		var quit = builder.get_object ("miQuit") as Gtk.MenuItem;
		quit.activate += (b) => { Gtk.main_quit(); };
		var about = builder.get_object ("miAbout") as Gtk.MenuItem;
		about.activate += (b) => { si.set_blinking(true); };
		var prefs = builder.get_object ("miPrefs") as Gtk.MenuItem;
		prefs.activate += (b) => {  win.show(); };

		// notification area icon (XXX draw a decent one)
		si = new Gtk.StatusIcon.from_stock(Gtk.STOCK_INFO);
		si.activate += (s) => { 
			if ( error_mode ) 
				err_win.show();
			else
				menu.popup(null,null,si.position_menu,0,
					Gtk.get_current_event_time());
		};
		si.set_visible(true); // XXX read from gconf: key_icon

		// error mode data
		command_hash = new GLib.HashTable<Gtk.Widget,string>(
			GLib.direct_hash,GLib.str_equal);
	}

	// This thread fills the event queue, parsing the
	// stdout of a child process 
	public void *smdThread() {
		bool rc = true;
		while(rc){
			rc = run_smd_loop();
		}
	
		return null;
	}

	public bool eval_smd_loop_message(string s){
		try {
			GLib.MatchInfo info = null;
			var r_tags = new GLib.Regex(
				"^([^:]+): smd-(client|server)@([^:]+): TAGS:(.*)$");
			var r_skip = new GLib.Regex(
				"^([^:]+): smd-(client|server)@([^:]+): ERROR");

			if (r_skip.match(s,0,null)) { return false; }
			if (!r_tags.match(s,0,out info)) {
				stderr.printf("unhandled smd-loop message: %s\n",s);
				return true;
			}
			
			var account = info.fetch(1);
			var host = info.fetch(3);
			var tags = info.fetch(4);
			
			GLib.MatchInfo i_args = null;
			var r_stats = new GLib.Regex(" stats::(.*)$");
			var r_error = new GLib.Regex(" error::(.*)$");

			if (r_stats.match(tags,0,out i_args)) {
				var r_neW = new GLib.Regex("new-mails\\(([0-9]+)\\)");
				var r_del = new GLib.Regex("del-mails\\(([0-9]+)\\)");
				GLib.MatchInfo i_new = null, i_del = null;
				var args = i_args.fetch(1);

				// check if matches
				var has_new = r_neW.match(args,0,out i_new); 
				var has_del = r_del.match(args,0,out i_del);

				int new_mails = 0;
				if (has_new) { new_mails = i_new.fetch(1).to_int();	}
				int del_mails = 0;
				if (has_del) { del_mails = i_del.fetch(1).to_int();	}

				if (host == "localhost" && (new_mails > 0 || del_mails > 0)) {
					events_lock.lock();
					events.append(
						Event.stats(account,host,new_mails, del_mails));
					events_lock.unlock();
				} else {
					// we skip non-error messages from the remote host
				}

				return false;
			} else if (r_error.match(tags,0,out i_args)) {
				var context = new GLib.Regex("context\\(([^\\)]+)\\)");
				var cause = new GLib.Regex("probable-cause\\(([^\\)]+)\\)");
				var human = new GLib.Regex("human-intervention\\(([^\\)]+)\\)");
				var actions=new GLib.Regex("suggested-actions\\((.*)\\) *$");

				GLib.MatchInfo i_ctx = null, i_cause = null, i_human = null;
				GLib.MatchInfo i_act = null;
				var args = i_args.fetch(1);

				if (! context.match(args,0,out i_ctx)){
					stderr.printf("smd-loop error with no context: %s\n",s);
					return true;
				}
				if (! cause.match(args,0,out i_cause)){
					stderr.printf("smd-loop error with no cause: %s\n",s);
					return true;
				}
				if (! human.match(args,0,out i_human)){
					stderr.printf("smd-loop error with no human: %s\n",s);
					return true;
				}
				var has_actions = actions.match(args,0,out i_act);

				// widget setup
				var l_ctx = builder.get_object("lContext") as Gtk.Label;
				l_ctx.set_text(i_ctx.fetch(1));
				var l_cause = builder.get_object("lCause") as Gtk.Label;
				l_cause.set_text(i_cause.fetch(1));
				if ( i_human.fetch(1) != "required" ){
					stderr.printf("smd-loop giving an avoidable error: %s\n",
						i_human.fetch(1));
					return true;
				}
				bool display_permissions = false;
				bool display_mail = false;
				bool display_commands = false;
				
				if (has_actions) {
					command_hash.remove_all();
					string acts = i_act.fetch(1);
					
					var r_perm = new GLib.Regex(
						"display-permissions\\(([^\\)]+)\\)");
					var r_mail = new GLib.Regex(
						"display-mail\\(([^\\)]+)\\)");
					var r_cmd = new GLib.Regex(
						"run\\(([^\\)]+)\\)");

					int from = 0;
					for (;acts != null && acts.len() > 0;){
						stderr.printf("--- %s\n",acts);
						MatchInfo i_cmd = null;
						if ( r_perm.match(acts,0,out i_cmd) ){
							display_permissions = true;
							i_cmd.fetch_pos(0,null,out from);
							string file = i_cmd.fetch(1);
							string output = null;
							try {
								GLib.Process.spawn_command_line_sync(
									"ls -ld " + file, out output, null);
								var l = builder.get_object("lPermissions") 
									as Gtk.Label;
								l.set_text(output);
							} catch (GLib.SpawnError e) {
								stderr.printf("Spawning ls: %s\n",e.message);
							}
						} else if ( r_mail.match(acts,0,out i_cmd) ){
							display_mail = true;
							i_cmd.fetch_pos(0,null,out from);
							string file = i_cmd.fetch(1);
							string output = null;
							try {
								var fn = builder.get_object("eMailName") 
									as Gtk.Entry;
								fn.set_text(file);
								GLib.Process.spawn_command_line_sync(
									"cat " + file, out output, null);
								var l = builder.get_object("tvMail") 
									as Gtk.TextView;
								Gtk.TextBuffer b = l.get_buffer();
								b.set_text(output,(int)output.size());
								Gtk.TextIter it,subj;
								b.get_start_iter(out it);
								it.forward_search("Subject:",
									Gtk.TextSearchFlags.TEXT_ONLY,
									out subj,null,null);
								var insert = b.get_insert();
								b.select_range(subj,subj);
								l.scroll_to_mark(insert,0.0,true,0.0,0.0);
							} catch (GLib.SpawnError e) {
								stderr.printf("Spawning ls: %s\n",e.message);
							}
						} else if ( r_cmd.match(acts,0,out i_cmd) ){
							display_commands = true;
							string command = i_cmd.fetch(1);
							i_cmd.fetch_pos(0,null,out from);
							var vb = builder.get_object("vbRun") as Gtk.VBox;
							var hb = new Gtk.HBox(false,10);
							var lbl = new Gtk.Label(command);
							lbl.set_alignment(0.0f,0.5f);
							var but = new Gtk.Button.from_stock("gtk-execute");
							command_hash.insert(but,command);
							but.clicked += (b) => {
								stderr.printf("%s\n",command_hash.lookup(b));
							};
							hb.pack_end(lbl,true,true,0);
							hb.pack_end(but,false,false,0);
							vb.pack_end(hb,true,true,0);
							hb.show_all();
						} else {
							stderr.printf("Unrecognized action: %s\n",acts);
							break;
						}
						acts = acts.substring(from);
					}
				}

				var x = builder.get_object("fDisplayPermissions") as Gtk.Widget;
				x.visible=display_permissions;
				x = builder.get_object("fDisplayMail") as Gtk.Widget; 
				x.visible=display_mail;
				x = builder.get_object("fRun") as Gtk.Widget; 
				x.visible=display_commands;
				
				events_lock.lock();
				events.append(Event.error(account,host));
				events_lock.unlock();
				return false;
			} else if (r_skip.match(s,0,out info)) {
				return false; // skip that message, not for us
			} else {
				stderr.printf("unhandled smd-loop message: %s\n",s);
				return true;
			}
		} catch (GLib.RegexError e) { stderr.printf("%s\n",e.message); }
		return true;
	}

	public bool run_smd_loop() {
		//string[] cmd = { smd_loop_cmd, "-v" };
		//string[] cmd = {"/bin/echo","default: smd-client@localhost: TAGS: stats::new-mails(1), del-mails(3)"};
		string[] cmd = {"/bin/echo","default: smd-client@foo: TAGS: error::context(testing smd-applet), probable-cause(generated on purpose), human-intervention(required), suggested-actions(display-permissions(/home/tassi) display-mail(/home/tassi/Mail/inbox/cur/1096282515.31281_2.garfield:2,S) run(echo a) run(echo b))"};
		int child_in;
		int child_out;
		int child_err;
		char[] buff = new char[1024];
		GLib.Pid pid;
		GLib.SpawnFlags flags = 0;
		try {
			bool rc = GLib.Process.spawn_async_with_pipes(
				null,cmd,null,flags,null,
				out pid, out child_in, out child_out, out child_err);
			if (rc) {
				var input = GLib.FileStream.fdopen(child_out,"r");
				string s = null;
				bool stop = false;
				while ( !stop && (s = input.gets(buff)) != null ) {
					stop = eval_smd_loop_message(s);
				}
				return false;
			} else {
				stderr.printf("Unable to execute "+smd_loop_cmd+"\n");
				throw new Exit.ABORT("Unable to run smd-loop");
			}
		} catch (GLib.Error e) {
			stderr.printf("Unable to execute "+
				smd_loop_cmd+": "+e.message+"\n");
			return false;
		}

		return true;
	}

	// process an event in the events queue by notifying the user
	// with its message
	bool eat_event() {
		Event e = null;

		// in error mode no events are processed
		if ( error_mode ) return true;

		// fetch the event
		events_lock.lock();
		if ( events.length() > 0) {
			e = events.nth(0).data;
			events.remove(e);
		}
		events_lock.unlock();

		// regular notification
		if ( e != null && gconf.get_bool(key_newmail) ){
			var not = new Notify.Notification(
				"Syncmaildir",e.message,"gtk-about",null);
			not.attach_to_status_icon(si);

			try { not.show(); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
		}

		// error notification
		if ( e != null && e.enter_error_mode ) {
			si.set_from_icon_name("error");
			si.set_blinking(true);
			error_mode = true;
		}

		return true; // re-schedule me please
	}
	
	// starts the thread and the timeout handler
	public void run() throws Exit { 
		// the timout function that will eventually notify the user
		GLib.Timeout.add(1000, eat_event);
		
		// the thread fills the event queue
		try { thread = GLib.Thread.create(smdThread,true); }
		catch (GLib.ThreadError e) { 
			stderr.printf("Unable to start a thread\n"); 
			throw new Exit.ABORT("Unable to spawn a thread");
		}

		Gtk.main(); 
		thread.join();
	}
}

// =================== main =====================================

static int main(string[] args){
	string PREFIX = SMDConf.PREFIX;

	// handle prefix
	if (! GLib.FileUtils.test(PREFIX + SMD_APPLET_UI,GLib.FileTest.EXISTS)) {
		smdApplet.smd_loop_cmd = GLib.Environment.get_variable("HOME") + 
			"/Projects/syncmaildir/smd-loop";
		stderr.printf("smd-applet not installed, " +
			"assuming smd-loop is: %s\n", smdApplet.smd_loop_cmd);
		smdApplet.smd_applet_ui = GLib.Environment.get_variable("HOME") + 
			"/Projects/syncmaildir/smd-applet.ui";
		stderr.printf("smd-applet not installed, " +
			"assuming smd-applet.ui is: %s\n", smdApplet.smd_applet_ui);
	} else {
		smdApplet.smd_loop_cmd = PREFIX + SMD_LOOP;
		smdApplet.smd_applet_ui = PREFIX + SMD_APPLET_UI; 
	}

	// we init gtk+ and notify
	Gtk.init (ref args);
	Notify.init("smd-applet");

	bool foo=false;
	GLib.OptionEntry[] oe = new GLib.OptionEntry[2];
	oe[0].long_name = "foo";
	oe[0].short_name = 'f';
	oe[0].flags = GLib.OptionFlags.NO_ARG;
	oe[0].arg = GLib.OptionArg.NONE;
	oe[0].arg_data = &foo;
	oe[0].description = "ffff";
	oe[0].arg_description = null;
	oe[1].long_name = null;
	var oc = new GLib.OptionContext(" - syncmaildir applet");
	oc.add_main_entries(oe,null);
	oc.parse(ref args);
	// XXX if foo then just show the confi win

	// go!
	var smd_applet = new smdApplet();
	try { smd_applet.run(); }
	catch (Exit e) { stderr.printf("abort: %s\n",e.message); }
	
	return 0;
}

// vim:set ts=4:
