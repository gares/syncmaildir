using Gtk;
using Notify;

class smdApplet {

	Gtk.Menu menu = null;
	Gtk.StatusIcon si = null;

	smdApplet(Gtk.Builder builder) {
        menu = builder.get_object ("mMain") as Menu;
		si = new StatusIcon.from_stock(Gtk.STOCK_NETWORK);

		var quit = builder.get_object ("miQuit") as MenuItem;
		quit.activate += (b) => { Gtk.main_quit(); };
		var about = builder.get_object ("miAbout") as MenuItem;
		about.activate += (b) => { Gtk.main_quit(); };

		si.activate += (s) => { 
			menu.popup(null,null,si.position_menu,0,
				Gtk.get_current_event_time());
		};
	
		si.set_visible(true);

		var not = new Notify.Notification("foo","bar","gtk-about",null);
		not.attach_to_status_icon(si);
		not.show();
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
