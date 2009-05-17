using Gtk;
using Notify;
using GConf;

class smdApplet {

	Gtk.Menu menu = null;
	Gtk.StatusIcon si = null;
	Gtk.Window win = null;
	GConf.Client gconf = null;

	static const string key_icon = "/apps/smd-applet/icon_only_on_errors";
	static const string key_newmail = "/apps/smd-applet/notify_new_mail";

	smdApplet(Gtk.Builder builder) {
		gconf = GConf.Client.get_default();

		win = builder.get_object("wPrefs") as Window;
		var close = builder.get_object("bClose") as Button;
		close.clicked += (b) =>  { win.hide(); };
		var bicon = builder.get_object("cbIcon") as CheckButton;
		bicon.set_active( gconf.get_bool(key_icon));
		bicon.toggled += (b) => {
			try { gconf.set_bool(key_icon,b.active); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
		};
		var bnotify = builder.get_object("cbNotify") as CheckButton;
		bnotify.set_active( gconf.get_bool(key_newmail));
		bnotify.toggled += (b) => {
			try { gconf.set_bool(key_newmail,b.active); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
		};

        menu = builder.get_object ("mMain") as Menu;
		var quit = builder.get_object ("miQuit") as MenuItem;
		quit.activate += (b) => { Gtk.main_quit(); };
		var about = builder.get_object ("miAbout") as MenuItem;
		about.activate += (b) => { Gtk.main_quit(); };
		var prefs = builder.get_object ("miPrefs") as MenuItem;
		prefs.activate += (b) => {  win.show(); };

		si = new StatusIcon.from_stock(Gtk.STOCK_NETWORK);
		si.activate += (s) => { 
			menu.popup(null,null,si.position_menu,0,
				Gtk.get_current_event_time());
		};
		si.set_visible(true);

		// var not = new Notify.Notification("foo","bar","gtk-about",null);
		// not.attach_to_status_icon(si);
		// not.show();
	}

	void run() { Gtk.main(); }

	static int main(string[] args){
		Gtk.init (ref args);
		Notify.init("smd-applet");
	
		var builder = new Builder ();
		try { builder.add_from_file ("smd-applet.ui"); } 
		catch (GLib.Error e) { stderr.printf("%s\n",e.message); return 1; }
	
		var smd_applet = new smdApplet(builder);
	
		smd_applet.run();
		
		return 0;
	}

}

// vim:set ts=4:
