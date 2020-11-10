module main;

import std.algorithm.mutation;
import std.algorithm;
import std.array;
import std.digest.sha;
import std.file;
import std.getopt;
import std.net.curl;
import std.path;
import std.range.primitives;
import std.range;
import std.stdio;
import std.string;
import std.traits;

import jsonizer;

/// Defines the wallpaper application mode.
enum WallpaperMode
{
	/// Don't apply the new wallpaper; just download.
	none,
	/// Apply the first new wallpaper downloaded since the last run.
	first,
	/// Always apply the latest wallpaper.
	newest,
}

/// Represents the Bing Wallpaper json metadata.
struct BingWallpaper
{
	mixin JsonizeMe;

	@jsonize:
	/// Incremental image ID.
	uint id;
	/// URL of the image.
	string url;
	/// Simple image name.
	string query;
	/// Date the image was published.
	string date;
	/// Image category.
	string category;
	/// Image copyright.
	string copyright;
	/// Image width.
	uint width;
	/// Image height.
	uint height;
	/// Image thumbnail URL.
	string thumbnail;
	/// Organization page.
	string orgpage;
	/// Image author.
	string author;
	/// Author homepage if applicable.
	string authorlink;
	/// Link for image license.
	string licenselink;
	/// Image title.
	string title;
	/// Image license.
	string license;
	/// Thumbnail width.
	string thnwidth;
	/// Thumbnail height.
	string thnheight;
	/// Image checksum (unknown type).
	string checksum;
}

/// File name/path to store the metadata json.
const string jsonNew = "bing-desktop.json";
/// Backup json for detecting new entries.
const string jsonOld = "bing-desktop.old";

/// URL to pull the metadata json from.
string jsonUrl = "http://az542455.vo.msecnd.net/bing/en-us";
/// Output directory to store the downloaded wallpapers.
string outDir;

/// Disables console pausing.
bool noPause;
/// Skip date validation and just download all wallpapers.
bool forceDownload;
/// Allow wallpapers to be re-downloaded and overwritten.
bool allowOverwrite;
/// Wallpaper application mode for this session.
auto wallpaperMode = WallpaperMode.newest;

private const string usageText =
`Lightweight multi-platform Bing Desktop client for downloading daily Bing wallpapers.

Usage:
	bingdesktop [options]

Options:`;

/// If `!noPause`, pauses the console output.
void pause()
{
	if (!noPause)
	{
		stdin.readln();
	}
}

int main(string[] args)
{
	try
	{
		auto result = getopt(args,
		                     "url|u",
		                     "The URL to the Bing Desktop metadata json.",
		                     &jsonUrl,

		                     "output|o",
		                     "Directory to save wallpapers.",
		                     &outDir,

		                     "no-pause|n",
		                     "Disable pause at the end of the program.",
		                     &noPause,

		                     "force-check|f",
		                     "Skip date validation and just download all wallpapers.",
		                     &forceDownload,

		                     "overwrite",
		                     "Allow wallpapers to be re-downloaded and overwritten.",
		                     &allowOverwrite,

		                     "mode|m",
		                     `Wallpaper selection mode. Valid options are "new" (first new wallpaper) and "newest". `
		                     ~ `Default mode is "none"`,
		                     &wallpaperMode);

		if (result.helpWanted)
		{
			auto optionsString = appender!string;
			defaultGetoptFormatter(optionsString, null, result.options);
			stdout.write(usageText);
			optionsString.data.splitLines().each!(x => stdout.writefln("\t%s", x));
			return 0;
		}
	}
	catch (Exception ex)
	{
		stderr.writeln(ex.msg);
		pause();
		return -1;
	}

	if (outDir.empty)
	{
		outDir = getcwd();
	}

	if (exists(jsonNew))
	{
		rename(jsonNew, jsonOld);
	}

	download(jsonUrl, jsonNew);

	try
	{
		if (forceDownload || exists(jsonOld))
		{
			if (forceDownload || hashFile(jsonNew) != hashFile(jsonOld))
			{
				stdout.writeln("Downloading new images...");
				downloadWallpapers();
			}
			else
			{
				stdout.writeln("Nothing new.");
				remove(jsonOld);
			}
		}
		else
		{
			downloadWallpapers();
		}
	}
	catch (Exception ex)
	{
		stderr.writeln(ex.msg);
		pause();
		return -1;
	}

	stdout.writeln();
	stdout.writeln("Operation complete.");
	pause();

	return 0;
}

/// Produces a SHA256 hash for a given file path.
ubyte[32] hashFile(in string path)
{
	auto file = File(path, "rb");
	SHA256 digest;

	foreach (ubyte[] buffer; file.byChunk(32 * 1024))
	{
		digest.put(buffer);
	}

	auto result = digest.finish();
	return result;
}

/// See isValidFilename in std.path
Range makeValidFilename(Range)(Range filename)
	if (((isRandomAccessRange!Range && hasLength!Range && hasSlicing!Range && isSomeChar!(ElementEncodingType!Range))
	     || isNarrowString!Range) && !isConvertibleToString!Range)
{
	Appender!Range result;

	foreach (c; filename)
	{
		version (Windows)
		{
			switch (c)
			{
				case 0: .. case 31:
				case '<':
				case '>':
				case ':':
				case '"':
				case '/':
				case '\\':
				case '|':
				case '?':
				case '*':
					result.put('_');
					break;

				default:
					result.put(c);
					break;
			}
		}
		else version (Posix)
		{
			result.put((c == 0 || c == '/') ? '_' : c);
		}
	}

	return result.data;
}

/// Downloads all available wallpapers.
void downloadWallpapers()
{
	auto text = readText(jsonNew);
	auto file = fromJSONString!(BingWallpaper[])(text);

	string wallpaperFilename;

	foreach (BingWallpaper i; file)
	{
		if (i.date.empty)
		{
			stdout.writeln("Entry missing date!");
			continue;
		}

		// Format is YYYY-MM-DD query.jpg
		string name = format!("%s-%s-%s %s.jpg")(i.date[0 .. 4], i.date[4 .. 6], i.date[6 .. 8], i.query.strip());

		name = makeValidFilename(name);

		string oldpath = buildNormalizedPath(outDir, format!("%d.jpg")(i.id));
		string newpath = buildNormalizedPath(outDir, name);

		// If the file has been copied with its original ID name,
		// rename it to "date query.jpg"
		// e.g: 2014-09-17 A dredge boat near the Glénan Islands.jpg
		if (exists(oldpath))
		{
			stdout.writefln("Renaming %d.jpg to %s", i.id, name);
			rename(oldpath, newpath);
		}
		else if (allowOverwrite || !exists(newpath)) // Otherwise, we just try to download.
		{
			stdout.writeln("Downloading: " ~ i.copyright);
			download(i.url, newpath);

			// The json is sorted newest to oldest.
			// So if the wallpaper mode is set to newest, we set it upon download.
			// Otherwise, we'll keep setting the string to the "first" new downloaded,
			// then apply the wallpaper later.
			switch (wallpaperMode)
			{
				default:
					break;

				case WallpaperMode.newest:
					wallpaperFilename = newpath;
					wallpaperMode = WallpaperMode.none;
					break;

				case WallpaperMode.first:
					wallpaperFilename = newpath;
					break;
			}
		}
		else
		{
			stdout.writeln("Skipping: " ~ name);
		}
	}

	// Use the last set "first" new wallpaper string, then set it.
	if (!wallpaperFilename.empty)
	{
		setWallpaper(wallpaperFilename);
	}
}

/// Sets the wallpaper.
/// Works on Windows and Linux with Gnome.
void setWallpaper(in string filename)
{
	version (Windows)
	{
		import core.sys.windows.windows : SystemParametersInfoA,
		                                  GetLastError;
		import core.sys.windows.winuser : SPI_SETDESKWALLPAPER,
		                                  SPIF_UPDATEINIFILE,
		                                  SPIF_SENDCHANGE;
		import core.thread              : Thread;
		import core.time                : msecs;

		wallpaperMode = WallpaperMode.none;

		bool result;
		for (size_t i; i < 4 && !result; i++)
		{
			auto stringz = absolutePath(filename).toStringz();
			result = SystemParametersInfoA(SPI_SETDESKWALLPAPER, 0, cast(void*)stringz,
			                               SPIF_UPDATEINIFILE | SPIF_SENDCHANGE) > 0;

			if (!result)
			{
				stderr.writefln("Failed to set wallpaper with error code %1$08X (%1$u)",
				                GetLastError());
				Thread.sleep(250.msecs);
			}
		}
	}
	else version (linux)
	{
		import std.process : executeShell;

		executeShell(`gsettings set org.gnome.desktop.background picture-uri "file://`
		             ~ absolutePath(filename, "/") ~ `"`);
	}
	else
	{
		stdout.writeln("Sorry, wallapers can't be set on your platform. They're still downloaded, though!");
	}
}
